// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod logging;
mod settings;
mod state;

use std::sync::Mutex;

use crossbeam_channel::Receiver;
use tauri::{Emitter, Manager};

use sdk::dsp::default_peq_bands;
use sdk::library::LibraryDb;
use sdk::{EngineEvent, EngineHandle, PlayMode};

use state::AppState;

/// 将引擎事件转发到前端 Tauri event
fn forward_engine_events(app_handle: tauri::AppHandle, event_rx: Receiver<EngineEvent>) {
    std::thread::spawn(move || {
        while let Ok(event) = event_rx.recv() {
            match event {
                EngineEvent::TrackChanged(path) => {
                    let path_clone = path.clone();
                    let _ = app_handle.emit("player:track_changed", &path);
                    if let Some(state) = app_handle.try_state::<AppState>() {
                        commands::apply_replaygain_volume_for_path(&path_clone, &state);
                    }
                }
                EngineEvent::PlaybackStopped => {
                    let _ = app_handle.emit("player:stopped", ());
                }
                EngineEvent::Position(pos) => {
                    let _ = app_handle.emit("player:position", pos);
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
            }
        }
    });
}

fn main() {
    logging::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            let data_dir = app.path().app_data_dir().expect("获取数据目录失败");
            std::fs::create_dir_all(&data_dir).ok();
            let db_path = data_dir.join("library.db");
            let db = LibraryDb::open(&db_path).expect("打开数据库失败");
            tracing::info!("数据库路径: {}", db_path.display());

            // 后台清理数据库中已丢失的文件记录
            {
                let db_for_clean = LibraryDb::open(&db_path).expect("打开数据库失败");
                std::thread::spawn(move || {
                    let tracks = db_for_clean.all_tracks(i64::MAX, 0).unwrap_or_default();
                    let mut removed = 0u32;
                    for t in &tracks {
                        if !std::path::Path::new(&t.path).exists() {
                            if db_for_clean.remove_track(t.id).is_ok() {
                                removed += 1;
                            }
                        }
                    }
                    if removed > 0 {
                        tracing::info!("清理 {removed} 条丢失文件记录");
                    }
                });
            }

            let (engine, event_rx) = EngineHandle::start();
            forward_engine_events(app.handle().clone(), event_rx);

            app.manage(AppState {
                engine,
                library: Mutex::new(db),
                db_path,
                peq_bands: Mutex::new(default_peq_bands()),
                play_mode: Mutex::new(PlayMode::Normal),
                replaygain_enabled: Mutex::new(false),
                base_volume: Mutex::new(1.0),
                current_track: Mutex::new(None),
            });

            // 注册全局快捷键
            use tauri_plugin_global_shortcut::GlobalShortcutExt;
            let gs = app.handle().global_shortcut();
            if let Err(e) = gs.on_shortcut("MediaPlayPause", |app: &tauri::AppHandle, _shortcut, event| {
                if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                    let state = app.state::<AppState>();
                    if state.engine.is_playing() {
                        state.engine.pause();
                    } else {
                        state.engine.resume();
                    }
                }
            }) {
                tracing::warn!("注册 MediaPlayPause 快捷键失败: {e}");
            }
            if let Err(e) = gs.on_shortcut("MediaNextTrack", |app: &tauri::AppHandle, _shortcut, event| {
                if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                    let state = app.state::<AppState>();
                    state.engine.next_track();
                }
            }) {
                tracing::warn!("注册 MediaNextTrack 快捷键失败: {e}");
            }
            if let Err(e) = gs.on_shortcut("MediaPreviousTrack", |app: &tauri::AppHandle, _shortcut, event| {
                if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                    let state = app.state::<AppState>();
                    state.engine.seek(0.0);
                }
            }) {
                tracing::warn!("注册 MediaPreviousTrack 快捷键失败: {e}");
            }

            tracing::info!("WaveLink 启动");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::play,
            commands::play_queue,
            commands::next_track,
            commands::pause,
            commands::resume,
            commands::stop,
            commands::audio_info,
            commands::read_text_file,
            commands::save_text_file,
            commands::load_ir,
            commands::clear_ir,
            commands::seek,
            commands::get_position,
            commands::get_duration,
            commands::set_volume,
            commands::set_play_mode,
            commands::get_play_mode,
            commands::remove_from_queue,
            commands::scan_dir,
            commands::search_tracks,
            commands::edit_tags,
            commands::delete_track,
            commands::batch_edit_tags,
            commands::get_tracks,
            commands::get_artists,
            commands::get_albums_by_artist,
            commands::get_tracks_by_album,
            commands::get_track_count,
            commands::get_cover,
            commands::get_file_cover_cmd,
            commands::lrc_lookup,
            commands::get_eq_bands,
            commands::set_peq_band,
            commands::reset_eq,
            commands::set_eq_preset,
            commands::set_stereo_widener,
            commands::set_replaygain,
            commands::get_replaygain,
            commands::analyze_replaygain,
            commands::analyze_all_replaygain,
            commands::analyze_track,
            commands::get_track_analyses,
            commands::analyze_all_tracks,
            commands::import_playlist_cmd,
            commands::export_playlist_cmd,
            commands::set_engine_config,
            commands::list_playlists,
            commands::save_playlist,
            commands::load_playlist,
            commands::delete_playlist,
            settings::save_settings,
            settings::load_settings,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
