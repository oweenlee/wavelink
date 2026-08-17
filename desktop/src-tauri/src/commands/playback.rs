use tauri::{AppHandle, Emitter, State};
use sdk::{DsdMode, Levels, PlayMode};
use sdk::output::{DeviceEvent, OutputDeviceInfo};
use crate::state::AppState;
use super::{apply_track_settings, lock_or_die};

#[tauri::command]
pub fn play(path: String, state: State<AppState>) {
    crate::streaming::cancel_active_stream(&state);
    *lock_or_die(&state.current_track) = Some(path.clone());
    apply_track_settings(&state);
    state.engine.play(path);
}

#[tauri::command]
pub fn play_queue(paths: Vec<String>, state: State<AppState>) {
    crate::streaming::cancel_active_stream(&state);
    if let Some(first) = paths.first() {
        *lock_or_die(&state.current_track) = Some(first.clone());
    }
    apply_track_settings(&state);
    state.engine.play_queue(paths);
}

/// 播放队列并从指定索引开始（CUE 整碟分轨等场景；0-based）
#[tauri::command]
pub fn play_queue_at(start_index: usize, paths: Vec<String>, state: State<AppState>) {
    crate::streaming::cancel_active_stream(&state);
    if let Some(first) = paths.first() {
        *lock_or_die(&state.current_track) = Some(first.clone());
    }
    apply_track_settings(&state);
    state.engine.play_queue_at(paths, start_index);
}

#[tauri::command]
pub fn next_track(state: State<AppState>) { state.engine.next_track(); }

#[tauri::command]
pub fn prev_track(state: State<AppState>) { state.engine.prev_track(); }

#[tauri::command]
pub fn pause(state: State<AppState>) { state.engine.pause(); }

#[tauri::command]
pub fn resume(state: State<AppState>) { state.engine.resume(); }

#[tauri::command]
pub fn stop(state: State<AppState>) {
    crate::streaming::cancel_active_stream(&state);
    state.engine.stop();
}

#[tauri::command]
pub fn seek(pos: f64, state: State<AppState>, app: AppHandle) {
    // 流式播放（STRM 边下边播）引擎流无 seek 能力（无 current_entry）：
    // 重启流从头播（字节偏移无法从秒数可靠换算，精确 seek 留后续 Range 方案）。
    // 缓存已完整的场景 restart 会自然走本地播放。
    if lock_or_die(&state.stream_handle).is_some() {
        crate::streaming::restart_stream(&app, &state);
        return;
    }
    state.engine.seek(pos);
}

#[tauri::command]
pub fn get_position(state: State<AppState>) -> f64 { state.engine.position_secs() }

#[tauri::command]
pub fn get_duration(state: State<AppState>) -> f64 { state.engine.duration_secs() }

#[tauri::command]
pub fn set_volume(vol: f64, state: State<AppState>) {
    *lock_or_die(&state.base_volume) = vol;
    state.engine.set_volume(vol as f32);
}

#[tauri::command]
pub fn set_play_mode(mode: PlayMode, state: State<AppState>) {
    *lock_or_die(&state.play_mode) = mode;
    state.engine.set_play_mode(mode);
}

#[tauri::command]
pub fn get_play_mode(state: State<AppState>) -> PlayMode {
    *lock_or_die(&state.play_mode)
}

#[tauri::command]
pub fn remove_from_queue(idx: usize, state: State<AppState>) {
    state.engine.remove_from_queue(idx);
}

#[tauri::command]
pub fn set_stereo_widener(enabled: bool, width: f32, state: State<AppState>) {
    state.engine.set_stereo_widener(enabled, width);
}

#[tauri::command]
pub fn set_replaygain(enabled: bool, state: State<AppState>) {
    *lock_or_die(&state.replaygain_enabled) = enabled;
    apply_track_settings(&state);
}

#[tauri::command]
pub fn get_replaygain(state: State<AppState>) -> bool {
    *lock_or_die(&state.replaygain_enabled)
}

#[tauri::command]
pub fn get_underrun_count(state: State<AppState>) -> u64 {
    state.engine.underrun_count()
}

#[tauri::command]
pub fn audio_info() -> serde_json::Value {
    serde_json::json!({
        "sample_rate": sdk::TARGET_SAMPLE_RATE,
        "channels": sdk::TARGET_CHANNELS,
    })
}

#[tauri::command]
pub fn list_audio_devices() -> Vec<String> {
    sdk::output::list_device_names()
}

/// 枚举所有音频输出设备（含详细配置信息）
#[tauri::command]
pub fn enumerate_audio_devices() -> Vec<OutputDeviceInfo> {
    sdk::output::enumerate_devices()
}

/// 启动设备热插拔监视器
#[tauri::command]
pub fn start_device_monitor(app: tauri::AppHandle, state: State<AppState>) {
    let monitor = sdk::output::start_device_monitor();
    let rx = monitor.receiver().clone();
    *lock_or_die(&state.device_monitor) = Some(monitor);
    let stop = state.device_monitor_stop.clone();
    stop.store(false, std::sync::atomic::Ordering::Relaxed);
    // 转发事件到前端
    std::thread::spawn(move || {
        loop {
            if stop.load(std::sync::atomic::Ordering::Relaxed) { break; }
            match rx.recv_timeout(std::time::Duration::from_millis(500)) {
                Ok(event) => {
                    let _ = app.emit(
                        "device:event",
                        serde_json::json!({
                            "type": match &event {
                                DeviceEvent::DeviceAdded(_) => "added",
                                DeviceEvent::DeviceRemoved(_) => "removed",
                                DeviceEvent::DefaultDeviceChanged => "default_changed",
                            },
                            "name": match &event {
                                DeviceEvent::DeviceAdded(n) | DeviceEvent::DeviceRemoved(n) => n.clone(),
                                DeviceEvent::DefaultDeviceChanged => String::new(),
                            },
                        }),
                    );
                }
                Err(_) => continue,
            }
        }
    });
}

/// 停止设备热插拔监视器
#[tauri::command]
pub fn stop_device_monitor(state: State<AppState>) {
    state.device_monitor_stop.store(true, std::sync::atomic::Ordering::Relaxed);
    *lock_or_die(&state.device_monitor) = None;
}

#[tauri::command]
pub fn set_audio_device(name: String, state: State<AppState>) {
    state.engine.set_output_device(name);
}

#[tauri::command]
pub fn set_audio_device_sync(name: String, state: State<AppState>) -> Result<(), String> {
    state.engine.set_output_device_sync(name).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn load_ir(path: String, state: State<AppState>) {
    state.engine.load_ir(path);
}

#[tauri::command]
pub fn clear_ir(state: State<AppState>) {
    state.engine.clear_ir();
}

#[tauri::command]
// Tauri 命令参数直接映射前端调用字段，不为此引入中间结构体
#[allow(clippy::too_many_arguments)]
pub fn set_engine_config(
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
    crossfade_ms: u32,
    auto_sample_rate: Option<bool>,
    exclusive_mode: Option<bool>,
    bit_perfect: Option<bool>,
    state: State<AppState>,
) {
    let cfg = sdk::EngineConfig {
        sample_rate,
        channels,
        buffer_ms,
        crossfade_ms,
        output_device: None,
        auto_sample_rate: auto_sample_rate.unwrap_or(false),
        exclusive_mode: exclusive_mode.unwrap_or(false),
        bit_perfect: bit_perfect.unwrap_or(false),
        ..Default::default()
    };
    state.engine.set_config(cfg);
}

#[tauri::command]
pub fn set_speed(speed: f32, state: State<AppState>) {
    state.engine.set_speed(speed);
}

#[tauri::command]
pub fn get_levels(state: State<AppState>) -> Levels {
    state.engine.levels()
}

/// 启用/禁用 Crossfeed（串音补偿）
#[tauri::command]
pub fn set_crossfeed(enabled: bool, state: State<AppState>) {
    state.engine.set_crossfeed(enabled);
}

/// 启用/禁用 ATH 噪声整形
#[tauri::command]
pub fn set_noise_shaping(enabled: bool, state: State<AppState>) {
    state.engine.set_noise_shaping(enabled);
}

/// 动态调整输出缓冲时长（毫秒），实时生效（仅 Oboe 后端支持）
#[tauri::command]
pub fn set_buffer_ms(ms: u32, state: State<AppState>) {
    state.engine.set_buffer_ms(ms);
}

/// 设置 ReplayGain 真峰值限制，None = 不限制
#[tauri::command]
pub fn set_replaygain_peak(peak: Option<f32>, state: State<AppState>) {
    state.engine.set_replaygain_peak(peak);
}

/// 从引擎 ringbuf 读取 PCM 样本（用于可视化）
#[tauri::command]
pub fn read_audio_samples(max_samples: u32, state: State<AppState>) -> Vec<f32> {
    let cap = max_samples.min(8192) as usize;
    let mut buf = vec![0.0f32; cap];
    let n = state.engine.read_samples(&mut buf);
    buf.truncate(n);
    buf
}

#[tauri::command]
pub fn session_interruption_began(state: State<AppState>) {
    state.engine.session_interruption_began();
}

#[tauri::command]
pub fn session_interruption_ended(state: State<AppState>) {
    state.engine.session_interruption_ended();
}

#[tauri::command]
pub fn start_capture(sample_rate: u32, channels: u32) -> Result<(), String> {
    sdk::start_global_capture(sample_rate, channels)
}

#[tauri::command]
pub fn stop_capture() {
    sdk::stop_global_capture();
}

#[tauri::command]
pub fn is_capturing() -> bool {
    sdk::is_capturing()
}

/// AutoEQ 耳机校正：传入型号名称应用，None 清除
#[tauri::command]
pub fn set_auto_eq(name: Option<String>, state: State<AppState>) {
    state.engine.set_auto_eq(name.as_deref());
}

/// 列出全部内嵌 AutoEQ 耳机档案名
#[tauri::command]
pub fn list_auto_eq_profiles() -> Vec<String> {
    sdk::dsp::autoeq_catalog().iter().map(|p| p.name.to_string()).collect()
}

/// 设置 DSD 处理模式（ToPcm / Dop）
#[tauri::command]
pub fn set_dsd_mode(mode: DsdMode, state: State<AppState>) {
    state.engine.set_dsd_mode(mode);
}

/// 启用/禁用真峰值限幅器
#[tauri::command]
pub fn set_limiter_enabled(enabled: bool, state: State<AppState>) {
    state.engine.set_limiter_enabled(enabled);
}

/// 启用/禁用 TPDF 抖动
#[tauri::command]
pub fn set_dither_enabled(enabled: bool, state: State<AppState>) {
    state.engine.set_dither_enabled(enabled);
}

/// 运行时切换输出采样率（下次播放生效）
#[tauri::command]
pub fn set_output_sample_rate(rate: u32, state: State<AppState>) {
    state.engine.set_output_sample_rate(rate);
}
