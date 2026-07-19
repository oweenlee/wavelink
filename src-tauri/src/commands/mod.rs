//! Tauri command 分发。按领域拆分子模块。

pub mod analysis;
pub mod dsp;
pub mod editor;
pub mod library;
pub mod nas_cmds;
pub mod playback;
pub mod utils;

// 不 re-export，main.rs 通过 commands::playback::play 等路径引用

use crate::state::AppState;

/// 根据 replaygain 开关和数据，设置引擎增益
pub(crate) fn apply_replaygain(state: &AppState) {
    let rg = *state.replaygain_enabled.lock().expect("replaygain_enabled mutex 被毒化");
    if rg {
        if let Some(ref cur) = *state.current_track.lock().expect("current_track mutex 被毒化") {
            if let Ok(db) = state.library.lock() {
                if let Ok(tracks) = db.search(cur, 1, 0) {
                    if let Some(t) = tracks.first() {
                        if let Some(gain) = t.track_gain {
                            state.engine.set_replaygain_gain_db(gain as f32);
                            return;
                        }
                    }
                }
            }
        }
    }
    state.engine.set_replaygain_gain_db(0.0);
}

/// 应用所有轨道级别设置（replaygain + 音量）
pub(crate) fn apply_track_settings(state: &AppState) {
    apply_replaygain(state);
    let base = *state.base_volume.lock().expect("base_volume mutex 被毒化");
    state.engine.set_volume(base as f32);
}

/// 切歌时由 forward_engine_events 调用
pub(crate) fn apply_replaygain_volume_for_path(path: &str, state: &AppState) {
    *state.current_track.lock().expect("current_track mutex 被毒化") = Some(path.to_string());
    apply_track_settings(state);
}
