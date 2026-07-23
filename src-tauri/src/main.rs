// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod events;
mod logging;
mod media_bridge;
mod nas;
mod settings;
mod setup;
mod state;
mod tray;

use std::sync::Mutex;
use tauri::Manager;

use sdk::dsp::default_peq_bands;
use sdk::library::LibraryDb;
use sdk::{EngineHandle, PlayMode};

use nas::NasManager;
use state::AppState;

fn main() {
    logging::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            let data_dir = app.path().app_data_dir().expect("get app data dir failed");
            std::fs::create_dir_all(&data_dir).ok();
            let db_path = data_dir.join("library.db");
            tracing::info!("db path: {}", db_path.display());

            // Background cleanup thread (separate connection)
            let clean_path = db_path.clone();
            std::thread::spawn(move || {
                let Ok(db) = LibraryDb::open(&clean_path) else { return };
                let tracks = db.all_tracks(i64::MAX, 0).unwrap_or_default();
                let mut removed = 0u32;
                for t in &tracks {
                    if !std::path::Path::new(&t.path).exists() && db.remove_track(t.id).is_ok() {
                        removed += 1;
                    }
                }
                if removed > 0 {
                    tracing::info!("cleaned {removed} missing file records");
                }
            });

            let db = LibraryDb::open(&db_path).expect("open db failed");

            let (engine, event_rx) = EngineHandle::start();
            events::forward_engine_events(app.handle().clone(), event_rx);

            let media_bridge = media_bridge::MediaBridge::new();
            let nas_manager = NasManager::new(&db_path);
            nas_manager.auto_mount_all();

            app.manage(AppState {
                engine,
                library: Mutex::new(db),
                db_path,
                peq_bands: Mutex::new(default_peq_bands()),
                play_mode: Mutex::new(PlayMode::Normal),
                replaygain_enabled: Mutex::new(false),
                base_volume: Mutex::new(1.0),
                current_track: Mutex::new(None),
                media_bridge,
                nas_manager,
            });

            if let Some(window) = app.get_webview_window("main") {
                setup::setup_window_appearance(&window);

                let handle = app.handle().clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        let _ = handle.get_webview_window("main").map(|w| w.hide());
                    }
                });
            }

            if let Err(e) = tray::create_tray(app.handle()) {
                tracing::warn!("create tray failed: {e}");
            }

            // Global shortcuts (macOS media keys handled by MPRemoteCommandCenter)
            #[cfg(not(target_os = "macos"))]
            register_global_shortcuts(app);

            tracing::info!("WaveLink 启动");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::playback::play,
            commands::playback::play_queue,
            commands::playback::next_track,
            commands::playback::prev_track,
            commands::playback::pause,
            commands::playback::resume,
            commands::playback::stop,
            commands::playback::get_underrun_count,
            commands::playback::audio_info,
            commands::playback::list_audio_devices,
            commands::playback::set_audio_device,
            commands::playback::load_ir,
            commands::playback::clear_ir,
            commands::playback::seek,
            commands::playback::get_position,
            commands::playback::get_duration,
            commands::playback::set_volume,
            commands::playback::set_play_mode,
            commands::playback::get_play_mode,
            commands::playback::remove_from_queue,
            commands::playback::set_stereo_widener,
            commands::playback::set_replaygain,
            commands::playback::get_replaygain,
            commands::playback::set_engine_config,
            commands::playback::set_speed,
            commands::playback::get_levels,
            commands::playback::start_capture,
            commands::playback::stop_capture,
            commands::playback::is_capturing,
            commands::library::scan_dir,
            commands::library::get_scan_folders,
            commands::library::remove_scan_folder,
            commands::library::reset_database,
            commands::library::search_tracks,
            commands::library::get_tracks,
            commands::library::get_artists,
            commands::library::get_albums_by_artist,
            commands::library::get_tracks_by_album,
            commands::library::get_all_albums,
            commands::library::get_track_count,
            commands::library::get_cover,
            commands::library::get_file_cover_cmd,
            commands::editor::edit_tags,
            commands::editor::delete_track,
            commands::editor::batch_edit_tags,
            commands::dsp::get_eq_bands,
            commands::dsp::set_peq_band,
            commands::dsp::reset_eq,
            commands::dsp::set_eq_preset,
            commands::analysis::analyze_replaygain,
            commands::analysis::analyze_all_replaygain,
            commands::analysis::analyze_track,
            commands::analysis::get_track_analyses,
            commands::analysis::analyze_all_tracks,
            commands::utils::read_text_file,
            commands::utils::save_text_file,
            commands::nas_cmds::nas_list,
            commands::nas_cmds::nas_add,
            commands::nas_cmds::nas_remove,
            commands::nas_cmds::nas_mount,
            commands::nas_cmds::nas_unmount,
            commands::nas_cmds::nas_is_mounted,
            settings::save_settings,
            settings::load_settings,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = event {
                if let Some(window) = app_handle.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                } else {
                    let _ = tauri::WebviewWindowBuilder::new(
                        app_handle,
                        "main",
                        tauri::WebviewUrl::App("index.html".into()),
                    )
                    .title("WaveLink")
                    .inner_size(1100.0, 750.0)
                    .build();
                }
            }
        });
}

#[cfg(not(target_os = "macos"))]
fn register_global_shortcuts(app: &mut tauri::App) {
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
        tracing::warn!("register MediaPlayPause shortcut failed: {e}");
    }
    if let Err(e) = gs.on_shortcut("MediaNextTrack", |app: &tauri::AppHandle, _shortcut, event| {
        if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
            let state = app.state::<AppState>();
            state.engine.next_track();
        }
    }) {
        tracing::warn!("register MediaNextTrack shortcut failed: {e}");
    }
    if let Err(e) = gs.on_shortcut("MediaPreviousTrack", |app: &tauri::AppHandle, _shortcut, event| {
        if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
            let state = app.state::<AppState>();
            state.engine.prev_track();
        }
    }) {
        tracing::warn!("register MediaPreviousTrack shortcut failed: {e}");
    }
}
