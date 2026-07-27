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

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};

#[derive(Debug, Clone, Copy, PartialEq)]
enum OboeFormat {
    I16,
    I32,
    F32,
}

impl OboeFormat {
    fn bits_per_sample(self) -> u16 {
        match self {
            OboeFormat::I16 => 16,
            OboeFormat::I32 | OboeFormat::F32 => 32,
        }
    }
}

/// Oboe 音频输出句柄
pub struct AudioOutputOboe {
    stream: Option<oboe::AudioStream>,
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
) -> Result<(oboe::AudioStream, OboeFormat), String> {
    use oboe::{AudioStreamBuilder, AudioOutputStreamSafe, PerformanceMode, SharingMode};

    let sharing = if exclusive { SharingMode::Exclusive } else { SharingMode::Shared };
    let mut builder = AudioStreamBuilder::default()
        .set_output()
        .set_channels(channels)
        .set_sample_rate(sample_rate)
        .set_sharing_mode(sharing)
        .set_performance_mode(PerformanceMode::LowLatency);

    match oboe_format {
        OboeFormat::I16 => {
            let mut tmp_buf: Vec<f32> = Vec::new();
            let cb_inner = inner.clone();
            let cb_playing = playing.clone();
            let stream = builder
                .set_i16()
                .set_callback(move |_, buffer: &mut [i16]| {
                    if !cb_playing.load(Ordering::Acquire) {
                        buffer.fill(0);
                        return;
                    }
                    tmp_buf.resize(buffer.len(), 0.0);
                    let mut guard = cb_inner.consumer.lock();
                    let n = guard.pop_slice(&mut tmp_buf);
                    for i in 0..n {
                        buffer[i] = (tmp_buf[i].clamp(-1.0, 1.0) * 32767.0) as i16;
                    }
                    if n < buffer.len() {
                        cb_inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                        buffer[n..].fill(0);
                    }
                })
                .open_stream()
                .map_err(|e| format!("Oboe I16 打开失败: {e:?}"))?;
            Ok((stream, OboeFormat::I16))
        }
        OboeFormat::I32 => {
            let mut tmp_buf: Vec<f32> = Vec::new();
            let cb_inner = inner.clone();
            let cb_playing = playing.clone();
            let stream = builder
                .set_i32()
                .set_callback(move |_, buffer: &mut [i32]| {
                    if !cb_playing.load(Ordering::Acquire) {
                        buffer.fill(0);
                        return;
                    }
                    tmp_buf.resize(buffer.len(), 0.0);
                    let mut guard = cb_inner.consumer.lock();
                    let n = guard.pop_slice(&mut tmp_buf);
                    for i in 0..n {
                        buffer[i] = (tmp_buf[i].clamp(-1.0, 1.0) * 2147483647.0) as i32;
                    }
                    if n < buffer.len() {
                        cb_inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                        buffer[n..].fill(0);
                    }
                })
                .open_stream()
                .map_err(|e| format!("Oboe I32 打开失败: {e:?}"))?;
            Ok((stream, OboeFormat::I32))
        }
        OboeFormat::F32 => {
            let cb_inner = inner.clone();
            let cb_playing = playing.clone();
            let stream = builder
                .set_f32()
                .set_callback(move |_, buffer: &mut [f32]| {
                    if !cb_playing.load(Ordering::Acquire) {
                        buffer.fill(0.0);
                        return;
                    }
                    let mut guard = cb_inner.consumer.lock();
                    let n = guard.pop_slice(buffer);
                    if n < buffer.len() {
                        cb_inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                        buffer[n..].fill(0.0);
                    }
                })
                .open_stream()
                .map_err(|e| format!("Oboe F32 打开失败: {e:?}"))?;
            Ok((stream, OboeFormat::F32))
        }
    }
}

// ─── 格式协商 ────────────────────────────────────────────────

fn negotiate_formats(channels: u16, sample_rate: u32, bit_depth: u16) -> Vec<OboeFormat> {
    let mut order = Vec::new();
    // 源位深优先
    match bit_depth {
        16 => order.push(OboeFormat::I16),
        24 | 32 => order.push(OboeFormat::I32),
        _ => order.push(OboeFormat::I32),
    }
    // fallback（去重）
    for fmt in [OboeFormat::I32, OboeFormat::I16, OboeFormat::F32] {
        if !order.contains(&fmt) {
            order.push(fmt);
        }
    }
    order
}

// ─── AudioOutput trait ───────────────────────────────────────

impl AudioOutput for AudioOutputOboe {
    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
    }

    fn resume(&self) {
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
            self.stream = None;
            match build_stream(
                self.inner.clone(),
                self.playing.clone(),
                self.channels as i32,
                rate as i32,
                self.exclusive,
                fmt,
            ) {
                Ok((stream, actual_fmt)) => {
                    self.stream = Some(stream);
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
                    let actual_rate = stream.sample_rate() as u32;
                    info!(
                        "Oboe 输出: {}Hz {}ch, {:?}, exclusive={}",
                        actual_rate, channels, fmt, exclusive,
                    );
                    let output = AudioOutputOboe {
                        stream: Some(stream),
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

    output.stream = None;
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
                output.stream = Some(stream);
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
                let is_default = info.device_type == oboe::AudioDeviceType::BuiltinSpeaker || devices.is_empty();

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
