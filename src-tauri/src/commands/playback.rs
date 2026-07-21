use tauri::State;
use sdk::{PlayMode};
use crate::state::AppState;
use super::apply_track_settings;

#[tauri::command]
pub fn play(path: String, state: State<AppState>) {
    *state.current_track.lock().expect("current_track mutex 被毒化") = Some(path.clone());
    apply_track_settings(&state);
    state.engine.play(path);
}

#[tauri::command]
pub fn play_queue(paths: Vec<String>, state: State<AppState>) {
    if let Some(first) = paths.first() {
        *state.current_track.lock().expect("current_track mutex 被毒化") = Some(first.clone());
    }
    apply_track_settings(&state);
    state.engine.play_queue(paths);
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
pub fn stop(state: State<AppState>) { state.engine.stop(); }

#[tauri::command]
pub fn seek(pos: f64, state: State<AppState>) { state.engine.seek(pos); }

#[tauri::command]
pub fn get_position(state: State<AppState>) -> f64 { state.engine.position_secs() }

#[tauri::command]
pub fn get_duration(state: State<AppState>) -> f64 { state.engine.duration_secs() }

#[tauri::command]
pub fn set_volume(vol: f64, state: State<AppState>) {
    *state.base_volume.lock().expect("base_volume mutex 被毒化") = vol;
    state.engine.set_volume(vol as f32);
}

#[tauri::command]
pub fn set_play_mode(mode: PlayMode, state: State<AppState>) {
    *state.play_mode.lock().expect("play_mode mutex 被毒化") = mode;
    state.engine.set_play_mode(mode);
}

#[tauri::command]
pub fn get_play_mode(state: State<AppState>) -> PlayMode {
    *state.play_mode.lock().expect("play_mode mutex 被毒化")
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
    *state.replaygain_enabled.lock().expect("replaygain_enabled mutex 被毒化") = enabled;
    apply_track_settings(&state);
}

#[tauri::command]
pub fn get_replaygain(state: State<AppState>) -> bool {
    *state.replaygain_enabled.lock().expect("replaygain_enabled mutex 被毒化")
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

#[tauri::command]
pub fn set_audio_device(name: String, state: State<AppState>) {
    state.engine.set_output_device(name);
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
pub fn set_engine_config(
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
    crossfade_ms: u32,
    state: State<AppState>,
) {
    let cfg = sdk::EngineConfig {
        sample_rate,
        channels,
        buffer_ms,
        crossfade_ms,
        output_device: None,
    };
    state.engine.set_config(cfg);
}
