//! Android Oboe/AAudio 音频输出后端
//!
//! 使用 `oboe` crate（Rust binding for Oboe/AAudio）。
//! 仅在 feature = "oboe-backend" 且 target_os = "android" 时编译。
//!
//! 特性：
//! - Exclusive + Shared 双模式，优先 Exclusive
//! - I16 / I32 / F32 格式，源位深优先
//! - 动态采样率切换（重建 stream）
//! - 低延迟回调

use std::marker::PhantomData;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use oboe::{
    AudioOutputCallback, AudioOutputStreamSafe, DataCallbackResult, Mono, Stereo,
};
use parking_lot::Mutex;
use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};

#[derive(Debug, Clone, Copy, PartialEq)]
enum OboeFormat {
    I16,
    F32,
}

/// 起播去爆点：从停（playing=false）到播的瞬间，ringbuf 首个样本几乎总是
/// 非零，波形从 0 直接跳到信号会形成 click/pop。前 ~5ms 线性渐变消除。
const FADE_IN_SAMPLES: usize = 240; // 5ms @ 48k

/// Oboe 实时数据回调。
///
/// oboe 0.6 不支持闭包回调，必须手动实现 `AudioOutputCallback`。
/// 泛型参数 `T` = 采样类型（i16/f32），`C` = 声道数标记（Mono/Stereo）。
struct OboeOutputCallback<T, C> {
    inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    tmp: Vec<f32>,
    /// 上一次回调时的播放状态（检测 false→true 起播，触发 fade-in）
    was_playing: bool,
    /// 剩余 fade-in 样本数（立体声帧）
    fade_remaining: usize,
    _marker: PhantomData<(T, C)>,
}

impl<T, C> OboeOutputCallback<T, C> {
    fn new(inner: Arc<AudioOutputInner>, playing: Arc<AtomicBool>) -> Self {
        Self {
            inner,
            playing,
            tmp: Vec::new(),
            was_playing: false,
            fade_remaining: 0,
            _marker: PhantomData,
        }
    }

    /// 每次回调开头调用：检测 playing false→true（起播/续播），触发 fade-in
    fn detect_start(&mut self) {
        let now = self.playing.load(Ordering::Acquire);
        if !self.was_playing && now {
            self.fade_remaining = FADE_IN_SAMPLES;
        }
        self.was_playing = now;
    }
}

/// 交织样本 fade-in（线性渐变）。fade_remaining 以帧为单位递减。
pub(crate) fn fade_in(fade_remaining: &mut usize, samples: &mut [f32]) {
    if *fade_remaining == 0 {
        return;
    }
    let total = FADE_IN_SAMPLES;
    let done = total - *fade_remaining;
    let n = samples.len() / 2;
    for i in 0..n {
        if *fade_remaining == 0 {
            break;
        }
        let gain = (done + i + 1) as f32 / total as f32;
        samples[i * 2] *= gain;
        samples[i * 2 + 1] *= gain;
        *fade_remaining -= 1;
    }
}

/// 单声道 fade-in（直接作用于输出切片）
pub(crate) fn fade_in_mono(fade_remaining: &mut usize, out: &mut [f32]) {
    if *fade_remaining == 0 {
        return;
    }
    let total = FADE_IN_SAMPLES;
    let done = total - *fade_remaining;
    for i in 0..out.len() {
        if *fade_remaining == 0 {
            break;
        }
        let gain = (done + i + 1) as f32 / total as f32;
        out[i] *= gain;
        *fade_remaining -= 1;
    }
}

/// 从 ringbuf 拉取交织 f32，不足补零；拿不到锁时按 underrun 处理。
fn read_samples(inner: &AudioOutputInner, playing: &AtomicBool, out: &mut [f32]) {
    if !playing.load(Ordering::Acquire) {
        out.fill(0.0);
        diag_fill(true);
        return;
    }
    let Some(mut guard) = inner.consumer.try_lock() else {
        inner.underrun_count.fetch_add(1, Ordering::Relaxed);
        out.fill(0.0);
        diag_fill(false);
        return;
    };
    let n = guard.pop_slice(out);
    if n < out.len() {
        inner.underrun_count.fetch_add(1, Ordering::Relaxed);
        out[n..].fill(0.0);
        diag_fill(false);
    } else {
        diag_fill(true);
    }
}

// ── 诊断探针：只在事件发生瞬间输出，不逐帧打日志 ──
static LAST_FRAMES: AtomicUsize = AtomicUsize::new(0);
static LAST_FILL_OK: AtomicBool = AtomicBool::new(true);

/// 帧大小变化检测（稳定时不输出；变化=潜在过度消费/欠载根因）
fn diag_frame_size(frames: usize) {
    let prev = LAST_FRAMES.swap(frames, Ordering::Relaxed);
    if prev != 0 && prev != frames {
        eprintln!("[OboeDiag] 帧大小变化: {} -> {}", prev, frames);
    }
}

/// underrun 突发起止检测
fn diag_fill(ok: bool) {
    let was_ok = LAST_FILL_OK.swap(ok, Ordering::Relaxed);
    if was_ok && !ok {
        eprintln!("[OboeDiag] underrun 突发开始");
    } else if !was_ok && ok {
        eprintln!("[OboeDiag] underrun 突发结束");
    }
}

impl AudioOutputCallback for OboeOutputCallback<f32, Stereo> {
    type FrameType = (f32, Stereo);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        data: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        let need = data.len() * 2;
        diag_frame_size(data.len());
        // 容量不足才扩容；读写一律用精确切片 [..need]，避免 tmp 偏大时
        // read_samples 从 ringbuf 过度取样本再丢弃（会造成内容跳变爆点）。
        if self.tmp.len() < need {
            self.tmp.resize(need, 0.0);
        }
        self.detect_start();
        read_samples(&self.inner, &self.playing, &mut self.tmp[..need]);
        fade_in(&mut self.fade_remaining, &mut self.tmp[..need]);
        for (i, frame) in data.iter_mut().enumerate() {
            frame.0 = self.tmp[i * 2];
            frame.1 = self.tmp[i * 2 + 1];
        }
        DataCallbackResult::Continue
    }
}

impl AudioOutputCallback for OboeOutputCallback<i16, Stereo> {
    type FrameType = (i16, Stereo);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        data: &mut [(i16, i16)],
    ) -> DataCallbackResult {
        let need = data.len() * 2;
        diag_frame_size(data.len());
        if self.tmp.len() < need {
            self.tmp.resize(need, 0.0);
        }
        self.detect_start();
        read_samples(&self.inner, &self.playing, &mut self.tmp[..need]);
        fade_in(&mut self.fade_remaining, &mut self.tmp[..need]);
        for (i, frame) in data.iter_mut().enumerate() {
            frame.0 = (self.tmp[i * 2].clamp(-1.0, 1.0) * 32768.0)
                .round()
                .clamp(-32768.0, 32767.0) as i16;
            frame.1 = (self.tmp[i * 2 + 1].clamp(-1.0, 1.0) * 32768.0)
                .round()
                .clamp(-32768.0, 32767.0) as i16;
        }
        DataCallbackResult::Continue
    }
}

impl AudioOutputCallback for OboeOutputCallback<f32, Mono> {
    type FrameType = (f32, Mono);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        data: &mut [f32],
    ) -> DataCallbackResult {
        diag_frame_size(data.len());
        self.detect_start();
        read_samples(&self.inner, &self.playing, data);
        fade_in_mono(&mut self.fade_remaining, data);
        DataCallbackResult::Continue
    }
}

impl AudioOutputCallback for OboeOutputCallback<i16, Mono> {
    type FrameType = (i16, Mono);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        data: &mut [i16],
    ) -> DataCallbackResult {
        let need = data.len();
        diag_frame_size(data.len());
        if self.tmp.len() < need {
            self.tmp.resize(need, 0.0);
        }
        self.detect_start();
        read_samples(&self.inner, &self.playing, &mut self.tmp[..need]);
        fade_in_mono(&mut self.fade_remaining, &mut self.tmp[..need]);
        for (i, s) in data.iter_mut().enumerate() {
            *s = (self.tmp[i].clamp(-1.0, 1.0) * 32768.0)
                .round()
                .clamp(-32768.0, 32767.0) as i16;
        }
        DataCallbackResult::Continue
    }
}

/// Oboe 音频输出句柄
pub struct AudioOutputOboe {
    stream: Mutex<Option<Box<dyn oboe::AudioStream>>>,
    inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
    exclusive: bool,
    oboe_format: OboeFormat,
    bit_depth: u16,
}

unsafe impl Send for AudioOutputOboe {}
unsafe impl Sync for AudioOutputOboe {}

// ─── 构建 stream ────────────────────────────────────────────

fn build_stream(
    inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    channels: i32,
    sample_rate: i32,
    exclusive: bool,
    oboe_format: OboeFormat,
) -> Result<(Box<dyn oboe::AudioStream>, OboeFormat), String> {
    use oboe::{AudioStreamBuilder, PerformanceMode, SharingMode};

    let sharing = if exclusive { SharingMode::Exclusive } else { SharingMode::Shared };
    let base = AudioStreamBuilder::default()
        .set_output()
        .set_sample_rate(sample_rate)
        .set_sharing_mode(sharing)
        .set_performance_mode(PerformanceMode::LowLatency);

    let stream: Box<dyn oboe::AudioStream> = if channels >= 2 {
        let b = base.set_stereo();
        match oboe_format {
            OboeFormat::I16 => Box::new(
                b.set_i16()
                    .set_callback(OboeOutputCallback::<i16, Stereo>::new(inner.clone(), playing.clone()))
                    .open_stream()
                    .map_err(|e| format!("Oboe I16 打开失败: {e:?}"))?,
            ),
            OboeFormat::F32 => Box::new(
                b.set_f32()
                    .set_callback(OboeOutputCallback::<f32, Stereo>::new(inner.clone(), playing.clone()))
                    .open_stream()
                    .map_err(|e| format!("Oboe F32 打开失败: {e:?}"))?,
            ),
        }
    } else {
        let b = base.set_mono();
        match oboe_format {
            OboeFormat::I16 => Box::new(
                b.set_i16()
                    .set_callback(OboeOutputCallback::<i16, Mono>::new(inner.clone(), playing.clone()))
                    .open_stream()
                    .map_err(|e| format!("Oboe I16(mono) 打开失败: {e:?}"))?,
            ),
            OboeFormat::F32 => Box::new(
                b.set_f32()
                    .set_callback(OboeOutputCallback::<f32, Mono>::new(inner.clone(), playing.clone()))
                    .open_stream()
                    .map_err(|e| format!("Oboe F32(mono) 打开失败: {e:?}"))?,
            ),
        }
    };

    let mut stream = stream;
    stream.start().map_err(|e| format!("Oboe start 失败: {e:?}"))?;
    Ok((stream, oboe_format))
}

// ─── 格式协商 ────────────────────────────────────────────────

fn negotiate_formats(_channels: u16, _sample_rate: u32, bit_depth: u16) -> Vec<OboeFormat> {
    let mut order = Vec::new();
    // 源位深优先
    match bit_depth {
        16 => order.push(OboeFormat::I16),
        _ => order.push(OboeFormat::F32),
    }
    // fallback（去重）
    for fmt in [OboeFormat::F32, OboeFormat::I16] {
        if !order.contains(&fmt) {
            order.push(fmt);
        }
    }
    order
}

// ─── AudioOutput trait ───────────────────────────────────────

impl AudioOutput for AudioOutputOboe {
    fn actual_sharing_mode(&self) -> Option<bool> {
        // 真实上报最终成功模式（先试 Exclusive 再回退 Shared 的实际结果）
        Some(self.exclusive)
    }

    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
        if let Some(s) = self.stream.lock().as_mut() {
            let _ = s.request_stop();
        }
    }

    fn resume(&self) {
        if let Some(s) = self.stream.lock().as_mut() {
            let _ = s.request_start();
        }
        self.playing.store(true, Ordering::Release);
    }

    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer {
        let buf_samples = (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (prod, new_cons) = rb.split();
        let mut guard = self.inner.consumer.lock();
        guard.clear();
        *guard = new_cons;
        prod
    }

    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    fn channels(&self) -> u32 {
        self.channels
    }

    fn set_sample_rate(&mut self, rate: u32) -> Result<u32, crate::error::EngineError> {
        if rate == self.sample_rate {
            return Ok(rate);
        }
        info!("Oboe 切换采样率: {}Hz → {}Hz", self.sample_rate, rate);

        let formats = negotiate_formats(self.channels as u16, rate, self.bit_depth);
        let mut last_err = String::new();

        for &fmt in &formats {
            *self.stream.lock() = None;
            match build_stream(
                self.inner.clone(),
                self.playing.clone(),
                self.channels as i32,
                rate as i32,
                self.exclusive,
                fmt,
            ) {
                Ok((stream, actual_fmt)) => {
                    *self.stream.lock() = Some(stream);
                    self.oboe_format = actual_fmt;
                    let actual = rate;
                    self.sample_rate = actual;
                    info!("Oboe 采样率切换成功: {}Hz, 格式: {:?}", actual, actual_fmt);
                    return Ok(actual);
                }
                Err(e) => {
                    last_err = e;
                    warn!("Oboe {:?} @ {}Hz 失败: {:?}", fmt, rate, last_err);
                }
            }
        }

        error!("Oboe 采样率切换失败: {}", last_err);
        Err(crate::error::EngineError::OutputOpenFailed(format!(
            "Oboe 不支持 {}Hz", rate
        )))
    }

    fn supported_sample_rates(&self) -> Vec<u32> {
        vec![44100, 48000, 88200, 96000, 176400, 192000]
    }

    fn set_bit_depth(&mut self, depth: u16) {
        self.bit_depth = depth;
    }

    fn set_buffer_ms(&mut self, ms: u32) {
        if ms == self.buffer_ms {
            return;
        }
        let old = self.buffer_ms;
        self.buffer_ms = ms;
        info!("Oboe 缓冲调整: {}ms → {}ms", old, ms);
        // 重建 ringbuf + stream 以应用新缓冲大小
        let buf_samples = (self.sample_rate as f32 * ms as f32 / 1000.0) as usize * self.channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (_prod, new_cons) = rb.split();
        {
            let mut guard = self.inner.consumer.lock();
            guard.clear();
            *guard = new_cons;
        }
        if let Err(e) = rebuild_stream(self) {
            error!("Oboe 重建 stream 失败 (缓冲调整): {}", e);
            self.buffer_ms = old; // 回退
        }
    }
}

// ─── open_inner ──────────────────────────────────────────────

pub(crate) fn open_inner(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    _device_name: Option<&str>,
    bit_depth: u16,
) -> Result<(AudioOutputOboe, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    let buf_samples = (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
    let rb = HeapRb::<f32>::new(buf_samples.max(64));
    let (producer, consumer) = rb.split();

    let inner = Arc::new(AudioOutputInner {
        consumer: parking_lot::Mutex::new(consumer),
        underrun_count: std::sync::atomic::AtomicU64::new(0),
        stream_failed: std::sync::atomic::AtomicBool::new(false),
    });

    let playing = Arc::new(AtomicBool::new(false));
    let format_order = negotiate_formats(channels as u16, sample_rate, bit_depth);

    // 先试 Exclusive，再试 Shared
    for &exclusive in &[true, false] {
        for &fmt in &format_order {
            match build_stream(
                inner.clone(),
                playing.clone(),
                channels as i32,
                sample_rate as i32,
                exclusive,
                fmt,
            ) {
                Ok((stream, _actual_fmt)) => {
                    let actual_rate = stream.get_sample_rate() as u32;
                    info!(
                        "Oboe 输出: {}Hz {}ch, {:?}, exclusive={}",
                        actual_rate, channels, fmt, exclusive,
                    );
                    let output = AudioOutputOboe {
                        stream: Mutex::new(Some(stream)),
                        inner: inner.clone(),
                        playing,
                        sample_rate: actual_rate,
                        channels,
                        buffer_ms,
                        exclusive,
                        oboe_format: fmt,
                        bit_depth,
                    };
                    return Ok((output, producer, inner, actual_rate));
                }
                Err(e) => {
                    warn!("Oboe exclusive={} {:?}: {}", exclusive, fmt, e);
                }
            }
        }
    }

    Err(format!(
        "Oboe 无法打开 {}Hz {}ch（所有格式/模式均失败）",
        sample_rate, channels
    ))
}

// ─── set_buffer_ms ───────────────────────────────────────────

/// 重建 Oboe stream 并替换缓冲 + 消费者
fn rebuild_stream(output: &mut AudioOutputOboe) -> Result<(), String> {
    let formats = negotiate_formats(output.channels as u16, output.sample_rate, output.bit_depth);
    let mut last_err = String::new();

    output.stream = Mutex::new(None);
    for &fmt in &formats {
        match build_stream(
            output.inner.clone(),
            output.playing.clone(),
            output.channels as i32,
            output.sample_rate as i32,
            output.exclusive,
            fmt,
        ) {
            Ok((stream, actual_fmt)) => {
                *output.stream.lock() = Some(stream);
                output.oboe_format = actual_fmt;
                info!("Oboe stream 重建成功: {}Hz {:?} exclusive={}", output.sample_rate, actual_fmt, output.exclusive);
                return Ok(());
            }
            Err(e) => {
                last_err = e;
            }
        }
    }
    Err(format!("Oboe stream 重建失败: {}", last_err))
}

// ─── 设备枚举 ────────────────────────────────────────────────

fn sr_config(sr: u32, depth: u8, fmt: crate::output::SampleFormat, exclusive: bool) -> crate::output::DeviceConfig {
    crate::output::DeviceConfig { sample_rate: sr, bit_depth: depth, channels: 2, sample_format: fmt, exclusive }
}

fn push_configs(configs: &mut Vec<crate::output::DeviceConfig>, sr: u32, has_i16: bool, has_f32: bool, exclusive: bool) {
    if has_i16 {
        configs.push(sr_config(sr, 16, crate::output::SampleFormat::I16, exclusive));
    }
    if has_f32 {
        configs.push(sr_config(sr, 32, crate::output::SampleFormat::F32, exclusive));
    }
}

pub(crate) fn enumerate_devices() -> Vec<crate::output::OutputDeviceInfo> {
    // 通过 Android Java API 枚举真实设备
    match oboe::AudioDeviceInfo::request(oboe::AudioDeviceDirection::Output) {
        Ok(info_list) => {
            let mut devices = Vec::new();
            for info in &info_list {
                let sample_rates: Vec<u32> = if info.sample_rates.is_empty() {
                    vec![44100, 48000]
                } else {
                    info.sample_rates.iter().map(|&r| r as u32).collect()
                };
                let has_i16 = info.formats.is_empty() || info.formats.contains(&oboe::AudioFormat::I16);
                let has_f32 = info.formats.is_empty() || info.formats.contains(&oboe::AudioFormat::F32);

                let is_usb = matches!(info.device_type,
                    oboe::AudioDeviceType::UsbDevice |
                    oboe::AudioDeviceType::UsbAccessory |
                    oboe::AudioDeviceType::UsbHeadset
                );
                // 内置扬声器 or 唯一设备标记为默认
                let is_default = matches!(info.device_type, oboe::AudioDeviceType::BuiltinSpeaker) || devices.is_empty();

                let mut configs = Vec::new();
                for &sr in &sample_rates {
                    push_configs(&mut configs, sr, has_i16, has_f32, true);
                }
                for &sr in &sample_rates {
                    push_configs(&mut configs, sr, has_i16, has_f32, false);
                }

                // 去重
                configs.sort_by(|a, b| a.sample_rate.cmp(&b.sample_rate).then(a.bit_depth.cmp(&b.bit_depth)));
                configs.dedup();

                devices.push(crate::output::OutputDeviceInfo {
                    id: info.id.to_string(),
                    name: info.product_name.clone(),
                    is_default,
                    is_usb,
                    configs,
                });
            }
            devices
        }
        Err(e) => {
            warn!("Oboe 设备枚举失败 (回退硬编码): {}", e);
            fallback_devices()
        }
    }
}

fn fallback_devices() -> Vec<crate::output::OutputDeviceInfo> {
    vec![crate::output::OutputDeviceInfo {
        id: "default".into(),
        name: "Android Audio Output".into(),
        is_default: true,
        is_usb: false,
        configs: vec![
            sr_config(44100, 32, crate::output::SampleFormat::I32, true),
            sr_config(48000, 32, crate::output::SampleFormat::I32, true),
            sr_config(96000, 32, crate::output::SampleFormat::I32, true),
            sr_config(192000, 32, crate::output::SampleFormat::I32, true),
            sr_config(44100, 16, crate::output::SampleFormat::I16, true),
            sr_config(48000, 16, crate::output::SampleFormat::I16, true),
        ],
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// fade-in 数学验证：前样本≈0（从静音渐变），末尾样本≈原值（不衰减）
    #[test]
    fn fade_in_ramps_from_zero_and_recovers_full() {
        let mut remaining = FADE_IN_SAMPLES;
        let mut samples: Vec<f32> = (0..FADE_IN_SAMPLES * 2)
            .map(|i| if i % 2 == 0 { 1.0 } else { -1.0 })
            .collect();
        fade_in(&mut remaining, &mut samples);
        // 渐变起点接近 0
        assert!(samples[0].abs() < 0.01, "起点应接近 0，实际 {}", samples[0]);
        // 渐变终点接近原值（第一个样本 gain ≈ 1/240，最后 ≈ 1）
        let last_idx = (FADE_IN_SAMPLES - 1) * 2;
        assert!(
            (samples[last_idx].abs() - 1.0).abs() < 0.01,
            "终点应接近原值，实际 {}",
            samples[last_idx]
        );
        // 单调递增（渐变无回跳）
        let mut prev = 0.0f32;
        for i in (0..FADE_IN_SAMPLES * 2).step_by(2) {
            let g = samples[i].abs();
            assert!(g >= prev - 1e-6, "渐变应单调：{g} < {prev}");
            prev = g;
        }
        // 剩余 0：fade 用尽后不再改数据
        assert_eq!(remaining, 0);
    }

    /// detect_start：playing false→true 触发 fade，持续 true 不重复触发
    #[test]
    fn detect_start_triggers_once() {
        let rb = ringbuf::HeapRb::<f32>::new(1024);
        let (producer, consumer) = rb.split();
        drop(producer);
        let inner = crate::output::AudioOutputInner {
            consumer: parking_lot::Mutex::new(consumer),
            underrun_count: std::sync::atomic::AtomicU64::new(0),
            stream_failed: std::sync::atomic::AtomicBool::new(false),
        };
        let playing = Arc::new(AtomicBool::new(false));
        let mut cb = OboeOutputCallback::<f32, Stereo>::new(inner, playing.clone());
        assert_eq!(cb.fade_remaining, 0);

        cb.detect_start(); // playing=false，不触发
        assert_eq!(cb.fade_remaining, 0);

        playing.store(true, Ordering::Release);
        cb.detect_start(); // false→true，触发
        assert_eq!(cb.fade_remaining, FADE_IN_SAMPLES);

        cb.detect_start(); // 持续 true，不重复触发（fade 在数据应用时递减）
        assert_eq!(cb.fade_remaining, FADE_IN_SAMPLES);
    }
}
