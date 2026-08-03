//! EngineHandle FRB 包装层
//!
//! 将 audio_core::engine::EngineHandle 包装为 flutter_rust_bridge 可调用的接口。
//! 引擎在后台管理：解码 → DSP → ringbuf 输出。

use arc_swap::ArcSwapOption;
use audio_core::dsp::PeqBand;
use audio_core::engine::{EngineEvent, EngineHandle, PlayMode};
use audio_core::EngineConfig;
use flutter_rust_bridge::frb;
use once_cell::sync::OnceCell;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// 引擎句柄无锁容器：渲染回调读取路径（with_engine）用 ArcSwap 原子 load，
/// 不在实时线程上取 std Mutex；handle 仅在 init/deinit 时 swap（极罕见）。
static ENGINE: ArcSwapOption<EngineHandle> = ArcSwapOption::const_empty();
static EVENT_RX: OnceCell<Mutex<Option<crossbeam_channel::Receiver<EngineEvent>>>> =
    OnceCell::new();

// 通过事件更新的状态
static CURRENT_PATH: Mutex<String> = Mutex::new(String::new());
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
static CURRENT_QUEUE: Mutex<Vec<String>> = Mutex::new(Vec::new());
static EVENT_OCCURRED: AtomicBool = AtomicBool::new(false);
static LAST_EVENT_KIND: Mutex<String> = Mutex::new(String::new());
// 事件队列：每次 poll 弹出一个，避免 while 循环丢事件
static EVENT_QUEUE: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());

#[derive(Default)]
pub struct LevelsDto {
    pub rms: f32,
    pub peak: f32,
    pub clip: bool,
}

fn with_engine<F, R>(f: F) -> Option<R>
where
    F: FnOnce(&EngineHandle) -> R,
{
    ENGINE.load_full().map(|h| f(&h))
}

// ── 初始化/销毁 ──

/// 初始化引擎，使用 HW_SAMPLE_RATE（由 Swift 设 set_hw_sample_rate 传入）
pub fn engine_init() -> Result<(), String> {
    let sr = crate::api::audio_output::get_hw_sample_rate();
    engine_init_ex(sr, 2, 280, 0, false, false, false, None)
}

/// 完整参数初始化引擎
pub fn engine_init_ex(
    sr: u32,
    channels: u16,
    buffer_ms: u32,
    crossfade_ms: u32,
    bit_perfect: bool,
    auto_sample_rate: bool,
    exclusive_mode: bool,
    output_device: Option<String>,
) -> Result<(), String> {
    // 同步 HW 速率记录：Android 无平台侧 setter，引擎以 sr 产出时
    // 遥测 outputRate 须保持一致；iOS 上 sr 本就取自该记录，幂等。
    crate::api::audio_output::set_hw_sample_rate_impl(sr);
    // 二次初始化：先停旧引擎再替换
    if let Some(old) = ENGINE.load_full() {
        old.stop();
    }
    if let Some(mtx) = EVENT_RX.get() {
        if let Ok(mut g) = mtx.lock() {
            *g = None;
        }
    }
    let config = EngineConfig {
        sample_rate: sr,
        channels: channels as u32,
        buffer_ms,
        crossfade_ms,
        bit_perfect,
        auto_sample_rate,
        exclusive_mode,
        output_device,
        ..Default::default()
    };
    let (handle, rx) = EngineHandle::start_with_config(config);
    // swap 入新句柄；若仍有旧句柄（并发重建），停掉它
    if let Some(old) = ENGINE.swap(Some(Arc::new(handle))) {
        old.stop();
    }
    if let Some(mtx) = EVENT_RX.get() {
        if let Ok(mut g) = mtx.lock() {
            *g = Some(rx);
        }
    } else {
        let _ = EVENT_RX.set(Mutex::new(Some(rx)));
    }
    // 清空旧事件队列
    EVENT_QUEUE.lock().unwrap().clear();
    EVENT_OCCURRED.store(false, Ordering::Release);
    Ok(())
}

/// 从引擎 ringbuf 读取交错 PCM 样本（供 iOS 音频回调使用）
///
/// 仅由 C FFI（audio_output_fill_buffer_stereo）调用，不暴露给 Dart。
#[frb(ignore)]
pub fn engine_read_samples(buf: &mut [f32]) -> usize {
    with_engine(|h| h.read_samples(buf)).unwrap_or(0)
}

/// 从引擎 ringbuf 读取最多 `frames` 帧的交错立体声 PCM（Android 流式播放用）。
///
/// 返回长度可能小于 `frames*2`（ringbuf 数据不足），调用方应自行处理欠载。
pub fn engine_read_samples_frames(frames: u32) -> Vec<f32> {
    let mut buf = vec![0.0f32; frames as usize * 2];
    let n = engine_read_samples(&mut buf);
    buf.truncate(n);
    buf
}

pub fn engine_deinit() {
    if let Some(h) = ENGINE.swap(None) {
        h.stop();
    }
    if let Some(mtx) = EVENT_RX.get() {
        if let Ok(mut g) = mtx.lock() {
            *g = None;
        }
    }
}

// ── 事件轮询（Dart 侧每分钟应调用数十次以保持事件更新） ──

pub fn engine_poll_events() -> Option<String> {
    {
        let guard = EVENT_RX.get().and_then(|mtx| mtx.lock().ok())?;
        let rx = guard.as_ref()?;

        while let Ok(event) = rx.try_recv() {
            match event {
                EngineEvent::TrackChanged(path) => {
                    *CURRENT_PATH.lock().unwrap() = path;
                    push_event("track_changed");
                }
                EngineEvent::PlaybackStopped => {
                    push_event("stopped");
                }
                EngineEvent::Error(e) => {
                    *LAST_ERROR.lock().unwrap() = e;
                    push_event("error");
                }
                EngineEvent::Spectrum(bands) => {
                    let mut arr = [0.0f32; 16];
                    for (i, &v) in bands.iter().take(16).enumerate() {
                        arr[i] = v;
                    }
                    crate::api::audio_output::update_spectrum(&arr);
                }
                EngineEvent::QueueChanged(queue, current) => {
                    *CURRENT_QUEUE.lock().unwrap() = queue;
                    *CURRENT_PATH.lock().unwrap() = current;
                    push_event("queue_changed");
                }
                _ => {}
            }
        }
    }
    // 每次只弹出一个事件，剩余保留在队列中
    EVENT_QUEUE.lock().unwrap().pop_front()
}

fn push_event(kind: &str) {
    *LAST_EVENT_KIND.lock().unwrap() = kind.to_string();
    EVENT_OCCURRED.store(true, Ordering::Release);
    EVENT_QUEUE.lock().unwrap().push_back(kind.to_string());
}

/// 检查是否有新的事件发生并返回事件类型
pub fn engine_take_event() -> Option<String> {
    if EVENT_OCCURRED.swap(false, Ordering::AcqRel) {
        Some(LAST_EVENT_KIND.lock().unwrap().clone())
    } else {
        None
    }
}

// ── 播放控制 ──

pub fn engine_play(path: String) {
    with_engine(|h| h.play(path));
}

pub fn engine_play_queue(paths: Vec<String>) {
    with_engine(|h| h.play_queue(paths));
}

pub fn engine_pause() {
    with_engine(|h| h.pause());
}

pub fn engine_resume() {
    with_engine(|h| h.resume());
}

pub fn engine_stop() {
    with_engine(|h| h.stop());
}

pub fn engine_seek(pos_secs: f64) {
    with_engine(|h| h.seek(pos_secs));
}

pub fn engine_next() {
    with_engine(|h| h.next_track());
}

pub fn engine_prev() {
    with_engine(|h| h.prev_track());
}

// ── DSP 控制 ──

pub fn engine_set_peq_band(index: u32, freq: f32, gain_db: f32, q: f32) {
    with_engine(|h| h.set_peq_band(index as usize, PeqBand { freq, gain_db, q, ..Default::default() }));
}

pub fn engine_apply_preset(preset_name: String) {
    let name = match preset_name.as_str() {
        "flat" => audio_core::dsp::PresetName::Flat,
        "rock" => audio_core::dsp::PresetName::Rock,
        "pop" => audio_core::dsp::PresetName::Pop,
        "dance" => audio_core::dsp::PresetName::Dance,
        "classical" => audio_core::dsp::PresetName::Classical,
        "soft" => audio_core::dsp::PresetName::Soft,
        "full_bass" | "fullBass" => audio_core::dsp::PresetName::FullBass,
        "full_treble" | "fullTreble" => audio_core::dsp::PresetName::FullTreble,
        "techno" => audio_core::dsp::PresetName::Techno,
        "vocals" => audio_core::dsp::PresetName::Vocals,
        _ => return,
    };
    let bands = audio_core::dsp::preset_bands(name);
    with_engine(|h| {
        for (i, band) in bands.iter().enumerate() {
            h.set_peq_band(i, band.clone());
        }
    });
}

pub fn engine_set_volume(vol: f32) {
    with_engine(|h| h.set_volume(vol.clamp(0.0, 2.0)));
}

pub fn engine_set_stereo_widener(enabled: bool, width: f32) {
    with_engine(|h| h.set_stereo_widener(enabled, width));
}

pub fn engine_set_speed(speed: f32) {
    with_engine(|h| h.set_speed(speed.clamp(0.25, 4.0)));
}

/// 设置引擎输出采样率（下次播放生效）。
///
/// iOS bit-perfect 协调：Swift 先把 `AVAudioSession` 设到目标速率并读回实际速率，
/// Dart 再调用本方法使引擎输出速率与设备一致。命令走 FIFO 通道，
/// 在同一首播放之前发送即可保证先于 play 生效。若速率 == 文件速率则不重采样（bit-perfect）。
pub fn engine_set_output_sample_rate(rate: u32) {
    with_engine(|h| h.set_output_sample_rate(rate));
}

pub fn engine_set_crossfeed(enabled: bool) {
    with_engine(|h| h.set_crossfeed(enabled));
}

/// 启用/禁用真峰值限幅
pub fn engine_set_limiter(enabled: bool) {
    with_engine(|h| h.set_limiter_enabled(enabled));
}

/// 启用/禁用抖动（含噪声整形）
pub fn engine_set_dither(enabled: bool) {
    with_engine(|h| h.set_dither_enabled(enabled));
}

pub fn engine_set_play_mode(mode: u8) {
    let pm = match mode {
        0 => PlayMode::Normal,
        1 => PlayMode::RepeatOne,
        2 => PlayMode::RepeatAll,
        3 => PlayMode::Shuffle,
        _ => return,
    };
    with_engine(|h| h.set_play_mode(pm));
}

pub fn engine_load_ir(path: String) {
    with_engine(|h| h.load_ir(path));
}

pub fn engine_clear_ir() {
    with_engine(|h| h.clear_ir());
}

pub fn engine_set_replaygain_gain(gain_db: f32) {
    with_engine(|h| h.set_replaygain_gain_db(gain_db));
}

// ── 查询 ──

pub fn engine_position_secs() -> f64 {
    with_engine(|h| h.position_secs()).unwrap_or(0.0)
}

pub fn engine_duration_secs() -> f64 {
    with_engine(|h| h.duration_secs()).unwrap_or(0.0)
}

pub fn engine_is_playing() -> bool {
    with_engine(|h| h.is_playing()).unwrap_or(false)
}

pub fn engine_current_path() -> String {
    CURRENT_PATH.lock().unwrap().clone()
}

pub fn engine_last_error() -> String {
    LAST_ERROR.lock().unwrap().clone()
}

pub fn engine_levels() -> LevelsDto {
    with_engine(|h| {
        let l = h.levels();
        LevelsDto {
            rms: l.rms,
            peak: l.peak,
            clip: l.clip,
        }
    })
    .unwrap_or_default()
}

pub fn engine_underrun_count() -> u64 {
    with_engine(|h| h.underrun_count()).unwrap_or(0)
}

pub fn engine_queue_len() -> i32 {
    CURRENT_QUEUE.lock().unwrap().len() as i32
}

pub fn engine_queue_path_at(index: i32) -> String {
    CURRENT_QUEUE
        .lock()
        .unwrap()
        .get(index as usize)
        .cloned()
        .unwrap_or_default()
}

pub fn engine_remove_from_queue(index: i32) {
    with_engine(|h| h.remove_from_queue(index as usize));
}
