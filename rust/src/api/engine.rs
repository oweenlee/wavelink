//! EngineHandle FRB 包装层
//!
//! 将 audio_core::engine::EngineHandle 包装为 flutter_rust_bridge 可调用的接口。
//! 引擎在后台管理：解码 → DSP → ringbuf 输出。

use audio_core::dsp::PeqBand;
use audio_core::engine::{EngineEvent, EngineHandle, PlayMode};
use audio_core::EngineConfig;
use once_cell::sync::OnceCell;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

static ENGINE: OnceCell<Mutex<Option<EngineHandle>>> = OnceCell::new();
static EVENT_RX: OnceCell<Mutex<Option<crossbeam_channel::Receiver<EngineEvent>>>> =
    OnceCell::new();

// 通过事件更新的状态
static CURRENT_PATH: Mutex<String> = Mutex::new(String::new());
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
static CURRENT_QUEUE: Mutex<Vec<String>> = Mutex::new(Vec::new());
static EVENT_OCCURRED: AtomicBool = AtomicBool::new(false);
static LAST_EVENT_KIND: Mutex<String> = Mutex::new(String::new());

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
    ENGINE
        .get()
        .and_then(|mtx| mtx.lock().ok())
        .and_then(|g| g.as_ref().map(f))
}

// ── 初始化/销毁 ──

/// 初始化引擎，使用 HW_SAMPLE_RATE（由 Swift 设 set_hw_sample_rate 传入）
pub fn engine_init() -> Result<(), String> {
    if ENGINE.get().is_some() {
        return Ok(());
    }
    let sr = crate::api::audio_output::get_hw_sample_rate();
    let config = EngineConfig {
        sample_rate: sr,
        channels: 2,
        buffer_ms: 280,
        crossfade_ms: 0,
        output_device: None,
        ..Default::default()
    };
    let (handle, rx) = EngineHandle::start_with_config(config);
    ENGINE.get_or_init(|| Mutex::new(Some(handle)));
    EVENT_RX.get_or_init(|| Mutex::new(Some(rx)));
    Ok(())
}

pub fn engine_deinit() {
    if let Some(mtx) = ENGINE.get() {
        if let Ok(mut g) = mtx.lock() {
            if let Some(ref h) = *g {
                h.stop();
            }
            *g = None;
        }
    }
    if let Some(mtx) = EVENT_RX.get() {
        if let Ok(mut g) = mtx.lock() {
            *g = None;
        }
    }
}

// ── 事件轮询（Dart 侧每分钟应调用数十次以保持事件更新） ──

pub fn engine_poll_events() -> Option<String> {
    let rx = EVENT_RX.get().and_then(|mtx| mtx.lock().ok())?;
    let rx = rx.as_ref()?;

    let mut kind: Option<String> = None;
    while let Ok(event) = rx.try_recv() {
        match event {
            EngineEvent::TrackChanged(path) => {
                *CURRENT_PATH.lock().unwrap() = path;
                kind = Some("track_changed".into());
            }
            EngineEvent::PlaybackStopped => {
                kind = Some("stopped".into());
            }
            EngineEvent::Error(e) => {
                *LAST_ERROR.lock().unwrap() = e;
                kind = Some("error".into());
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
                kind = Some("queue_changed".into());
            }
            _ => {}
        }
    }
    if let Some(ref k) = kind {
        *LAST_EVENT_KIND.lock().unwrap() = k.clone();
        EVENT_OCCURRED.store(true, Ordering::Release);
    }
    kind
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
    with_engine(|h| h.set_peq_band(index as usize, PeqBand { freq, gain_db, q }));
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

pub fn engine_set_crossfeed(enabled: bool) {
    with_engine(|h| h.set_crossfeed(enabled));
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
