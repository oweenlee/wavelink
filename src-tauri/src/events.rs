/// 引擎事件 → Tauri 前端事件转发

use crossbeam_channel::Receiver;
use tauri::{Emitter, Manager};
use sdk::EngineEvent;
use crate::state::AppState;

pub fn forward_engine_events(app_handle: tauri::AppHandle, event_rx: Receiver<EngineEvent>) {
    std::thread::spawn(move || {
        while let Ok(event) = event_rx.recv() {
            match event {
                EngineEvent::TrackChanged(path) => {
                    let path_clone = path.clone();
                    let _ = app_handle.emit("player:track_changed", &path);
                    if let Some(state) = app_handle.try_state::<AppState>() {
                        crate::commands::apply_replaygain_volume_for_path(&path_clone, &state);

                        if let Ok(db) = state.library.lock() {
                            if let Ok(Some(track)) = db.get_track_by_path(&path) {
                                let title = track.title.as_deref().unwrap_or("未知曲目");
                                let artist = track.artist.as_deref().unwrap_or("未知艺术家");
                                let album = track.album.as_deref().unwrap_or("");
                                let duration_ms = track.duration
                                    .map(|d| (d * 1000.0) as u64)
                                    .unwrap_or(0);
                                state.media_bridge.update_metadata(title, artist, album, duration_ms);
                                state.media_bridge.update_playback_state(true);
                            }
                        }
                    }
                }
                EngineEvent::PlaybackStopped => {
                    let _ = app_handle.emit("player:stopped", ());
                    if let Some(state) = app_handle.try_state::<AppState>() {
                        state.media_bridge.clear();
                    }
                }
                EngineEvent::Position(pos) => {
                    let _ = app_handle.emit("player:position", pos);
                    if let Some(state) = app_handle.try_state::<AppState>() {
                        state.media_bridge.update_position((pos * 1000.0) as u64);
                    }
                }
                EngineEvent::DurationSecs(dur) => {
                    let _ = app_handle.emit("player:duration", dur);
                }
                EngineEvent::Error(msg) => {
                    tracing::error!("引擎错误: {msg}");
                    let _ = app_handle.emit("player:error", msg);
                }
                EngineEvent::QueueChanged(paths, current) => {
                    let _ = app_handle.emit(
                        "player:queue_changed",
                        serde_json::json!({ "paths": paths, "current": current }),
                    );
                }
                EngineEvent::Spectrum(bands) => {
                    let _ = app_handle.emit("player:spectrum", &bands);
                }
            }
        }
    });
}
