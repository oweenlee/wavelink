//! 桌面端音频引擎 FFI（镜像 mobile `api/engine.rs`）
//!
//! 通过 flutter_rust_bridge 暴露 audio_core 引擎；crate 通过 cpal /
//! AudioUnit / WASAPI 走真实输出。事件采用**轮询模型**（与 mobile 一致）：
//! Dart 侧定时调用 `wavelink_poll_event()` 取回事件 JSON。

use std::collections::VecDeque;
use std::sync::Mutex;

use audio_core::engine::{EngineEvent, EngineHandle, PlayMode};
use audio_core::stream::StreamHandle;
use audio_core::EngineConfig;
use cpal::traits::{DeviceTrait, HostTrait};
use crossbeam_channel::Receiver;
use flutter_rust_bridge::frb;
use serde_json::json;

/// 引擎句柄 + 事件接收器（init 时建立，deinit 时取出释放，可重新 init）。
/// 用 `Mutex<Option<..>>` 而非 OnceCell：OnceCell set 后不可取出，会导致
/// deinit → init 循环失效（再 init 永远命中「已初始化」分支）。
static ENGINE: Mutex<Option<(EngineHandle, Receiver<EngineEvent>)>> = Mutex::new(None);
/// 事件队列：每次 poll 从 channel 抽干入队，再返回一个，避免 while 循环丢事件
static EVENT_QUEUE: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
/// 最近一次错误
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
/// 当前曲目路径
static CURRENT_PATH: Mutex<String> = Mutex::new(String::new());

fn push_event(value: serde_json::Value) {
    if let Ok(s) = serde_json::to_string(&value) {
        EVENT_QUEUE.lock().unwrap().push_back(s);
    }
}

// ── 网络音源喂流支持（crate 内部，供 webdav.rs / smb.rs 使用）──

/// 启动 core 流式播放并返回喂流句柄（镜像 mobile `api::engine::engine_start_stream`）。
/// webdav.rs 的 `engine_play_webdav_stream` / smb.rs 的 `engine_play_smb_stream`
/// 拿到 StreamHandle 后由后台 task 从远端拉字节喂入 core 解码。
pub(crate) fn engine_start_stream(
    format_hint: Option<String>,
    content_length: Option<u64>,
) -> Result<StreamHandle, String> {
    let engine = ENGINE.lock().unwrap();
    engine
        .as_ref()
        .map(|(h, _)| h.play_stream_sync(format_hint, content_length))
        .ok_or_else(|| "引擎未初始化".to_string())?
        .map_err(|e| e.to_string())
}

/// 喂流后台 task 失败时注入 error 事件（镜像 mobile `engine_notify_stream_error`）。
pub(crate) fn notify_stream_error(message: String) {
    *LAST_ERROR.lock().unwrap() = message;
    push_event(json!({"type": "error"}));
}

// ── 初始化 / 销毁 ──

/// 初始化引擎。成功返回 null；失败返回错误信息字符串。
///
/// `output_device` 为 null 表示系统默认设备。幂等：已初始化时直接返回成功。
#[frb]
pub fn wavelink_init(
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
    bit_perfect: bool,
    exclusive_mode: bool,
    output_device: Option<String>,
) -> Option<String> {
    let mut engine = ENGINE.lock().unwrap();
    if engine.is_some() {
        // 已初始化：仅重置错误，幂等返回成功
        *LAST_ERROR.lock().unwrap() = String::new();
        return None;
    }
    let device = output_device.filter(|s| !s.is_empty());
    let config = EngineConfig {
        sample_rate: if sample_rate == 0 { 44100 } else { sample_rate },
        channels: if channels == 0 { 2 } else { channels },
        buffer_ms: if buffer_ms == 0 { 280 } else { buffer_ms },
        crossfade_ms: 0,
        output_device: device,
        auto_sample_rate: false,
        exclusive_mode,
        bit_perfect,
        ..Default::default()
    };
    let (handle, rx) = EngineHandle::start_with_config(config);
    *engine = Some((handle, rx));
    drop(engine);
    EVENT_QUEUE.lock().unwrap().clear();
    None
}

/// 释放引擎。与 `wavelink_init` 配对，可重新 init（ENGINE 可重置）。
#[frb]
pub fn wavelink_deinit() {
    if let Some((handle, _)) = ENGINE.lock().unwrap().take() {
        handle.stop();
    }
    EVENT_QUEUE.lock().unwrap().clear();
}

// ── 播放控制 ──

/// 播放单个文件（异步）。
#[frb]
pub fn wavelink_play(path: String) {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.play(path);
    }
}

/// 以 JSON 数组（["/a","/b"]）设置播放队列并从第一首播放。
#[frb]
pub fn wavelink_play_queue_json(json: String) {
    let Ok(paths) = serde_json::from_str::<Vec<String>>(&json) else {
        *LAST_ERROR.lock().unwrap() = "队列 JSON 解析失败".into();
        push_event(json!({"type": "error", "message": "队列 JSON 解析失败"}));
        return;
    };
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.play_queue(paths);
    }
}

/// 以 JSON 数组设置播放队列并从 `start_index`（0-based）开始播放（CUE 分轨场景）。
#[frb]
pub fn wavelink_play_queue_at_json(json: String, start_index: u32) {
    let Ok(paths) = serde_json::from_str::<Vec<String>>(&json) else {
        *LAST_ERROR.lock().unwrap() = "队列 JSON 解析失败".into();
        push_event(json!({"type": "error", "message": "队列 JSON 解析失败"}));
        return;
    };
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.play_queue_at(paths, start_index as usize);
    }
}

#[frb]
pub fn wavelink_pause() {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.pause();
    }
}

#[frb]
pub fn wavelink_resume() {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.resume();
    }
}

#[frb]
pub fn wavelink_stop() {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.stop();
    }
}

#[frb]
pub fn wavelink_next() {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.next_track();
    }
}

#[frb]
pub fn wavelink_prev() {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.prev_track();
    }
}

/// 跳转到指定位置（秒）
#[frb]
pub fn wavelink_seek(pos_secs: f64) {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.seek(pos_secs);
    }
}

/// 设置音量（0.0 ~ 2.0）
#[frb]
pub fn wavelink_set_volume(vol: f32) {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.set_volume(vol);
    }
}

/// 设置播放模式：0 顺序 / 1 单曲循环 / 2 列表循环 / 3 随机
#[frb]
pub fn wavelink_set_play_mode(mode: i32) {
    let play_mode = match mode {
        1 => PlayMode::RepeatOne,
        2 => PlayMode::RepeatAll,
        3 => PlayMode::Shuffle,
        _ => PlayMode::Normal,
    };
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.set_play_mode(play_mode);
    }
}

/// 设置输出设备（null = 系统默认），下次播放生效
#[frb]
pub fn wavelink_set_output_device(name: Option<String>) {
    if let Some((handle, _)) = ENGINE.lock().unwrap().as_ref() {
        handle.set_output_device(name.unwrap_or_default());
    }
}

// ── 查询 ──

#[frb]
pub fn wavelink_position_secs() -> f64 {
    ENGINE.lock().unwrap().as_ref().map(|(h, _)| h.position_secs()).unwrap_or(0.0)
}

#[frb]
pub fn wavelink_duration_secs() -> f64 {
    ENGINE.lock().unwrap().as_ref().map(|(h, _)| h.duration_secs()).unwrap_or(0.0)
}

#[frb]
pub fn wavelink_is_playing() -> bool {
    match ENGINE.lock().unwrap().as_ref() {
        Some((h, _)) if h.is_playing() => true,
        _ => false,
    }
}

#[frb]
pub fn wavelink_underrun_count() -> u64 {
    ENGINE.lock().unwrap().as_ref().map(|(h, _)| h.underrun_count()).unwrap_or(0)
}

#[frb]
pub fn wavelink_current_path() -> String {
    CURRENT_PATH.lock().unwrap().clone()
}

#[frb]
pub fn wavelink_last_error() -> String {
    LAST_ERROR.lock().unwrap().clone()
}

// ── 事件轮询 ──

/// 抽干事件 channel 入队，再返回一个事件 JSON（需释放）；无事件返回 null。
///
/// Dart 侧应以 ~20-50ms 间隔高频调用，避免事件堆积。
#[frb]
pub fn wavelink_poll_event() -> Option<String> {
    // 1. 抽干 channel
    if let Some((_, rx)) = ENGINE.lock().unwrap().as_ref() {
        while let Ok(ev) = rx.try_recv() {
            match ev {
                EngineEvent::TrackChanged(path) => {
                    *CURRENT_PATH.lock().unwrap() = path.clone();
                    push_event(json!({"type": "track_changed", "path": path}));
                }
                EngineEvent::PlaybackStopped => {
                    push_event(json!({"type": "stopped"}));
                }
                EngineEvent::Position(secs) => {
                    push_event(json!({"type": "position", "value": secs}));
                }
                EngineEvent::DurationSecs(secs) => {
                    push_event(json!({"type": "duration", "value": secs}));
                }
                EngineEvent::Error(e) => {
                    *LAST_ERROR.lock().unwrap() = e.clone();
                    push_event(json!({"type": "error", "message": e}));
                }
                EngineEvent::QueueChanged(queue, current) => {
                    *CURRENT_PATH.lock().unwrap() = current.clone();
                    push_event(json!({"type": "queue_changed", "queue": queue, "current": current}));
                }
                EngineEvent::Spectrum(bands) => {
                    push_event(json!({"type": "spectrum", "bands": bands}));
                }
                EngineEvent::Levels(lv) => {
                    push_event(json!({"type": "levels", "rms": lv.rms, "peak": lv.peak, "clip": lv.clip}));
                }
                EngineEvent::DopActive(active) => {
                    push_event(json!({"type": "dop_active", "value": active}));
                }
            }
        }
    }
    // 2. 弹出一个事件返回
    EVENT_QUEUE.lock().unwrap().pop_front()
}

// ── 设备枚举（桌面特有）──

/// 枚举可用输出设备，返回 JSON 字符串（需释放）：["设备名1","设备名2"]
#[frb]
pub fn wavelink_enumerate_devices() -> Vec<String> {
    let host = cpal::default_host();
    match host.output_devices() {
        Ok(devs) => devs.filter_map(|d| d.name().ok()).collect(),
        Err(_) => Vec::new(),
    }
}
