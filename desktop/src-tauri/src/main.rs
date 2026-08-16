// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod events;
mod logging;
mod media_bridge;
mod nas;
mod remote;
mod settings;
mod setup;
mod state;
mod tray;

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::Manager;

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use sdk::dsp::default_peq_bands;
use sdk::library::{LibraryDb, Scanner};
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
            settings::init(&data_dir);
            setup::cleanup_part_files(&data_dir);
            setup::cleanup_cache_oversize(&data_dir);
            let db_path = data_dir.join("library.db");
            tracing::info!("db path: {}", db_path.display());

            // 文件夹监控：文件系统事件监听（替代定时轮询）
            let watch_path = db_path.clone();
            std::thread::spawn(move || {
                let Ok(db) = LibraryDb::open(&watch_path) else { return };
                let (tx, rx) = crossbeam_channel::unbounded();

                let mut watcher: RecommendedWatcher = Watcher::new(
                    move |res: Result<notify::Event, notify::Error>| {
                        if let Ok(event) = res {
                            let _ = tx.send(event);
                        }
                    },
                    notify::Config::default(),
                )
                .expect("创建文件监听器失败");

                let folders = db.list_folders().unwrap_or_default();
                for folder in &folders {
                    if let Err(e) = watcher.watch(Path::new(folder), RecursiveMode::Recursive) {
                        tracing::warn!("无法监听 [{folder}]: {e}");
                    }
                }
                tracing::info!("文件监听启动 ({} 个目录)", folders.len());

                let mut pending: HashSet<String> = HashSet::new();
                let mut last_scan = Instant::now();
                let mut last_refresh = Instant::now();
                let mut current_folders = folders;

                loop {
                    // 每 60s 检查扫描目录列表是否有增减
                    if last_refresh.elapsed() >= Duration::from_secs(60) {
                        if let Ok(updated) = db.list_folders() {
                            for f in &current_folders {
                                if !updated.contains(f) {
                                    let _ = watcher.unwatch(Path::new(f));
                                }
                            }
                            for f in &updated {
                                if !current_folders.contains(f) {
                                    if let Err(e) = watcher.watch(Path::new(f), RecursiveMode::Recursive) {
                                        tracing::warn!("无法监听 [{f}]: {e}");
                                    }
                                }
                            }
                            current_folders = updated;
                        }
                        last_refresh = Instant::now();
                    }

                    // 收集文件系统事件
                    while let Ok(event) = rx.try_recv() {
                        if matches!(event.kind,
                            EventKind::Create(_) | EventKind::Modify(_)
                            | EventKind::Remove(_) | EventKind::Any
                        ) {
                            if let Some(path) = event.paths.first() {
                                for folder in &current_folders {
                                    if path.starts_with(folder) {
                                        pending.insert(folder.clone());
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    // 防抖 2 秒后扫描有变更的目录
                    if !pending.is_empty() && last_scan.elapsed() >= Duration::from_secs(2) {
                        let to_scan: Vec<_> = pending.drain().collect();
                        for folder in &to_scan {
                            let path = Path::new(folder);
                            if !path.is_dir() {
                                continue;
                            }
                            match Scanner::scan_directory(&db, path) {
                                Ok(r) => {
                                    if r.scanned > 0 || r.removed > 0 {
                                        tracing::info!("自动扫描 [{folder}]: +{} -{} e{}",
                                            r.scanned, r.removed, r.errors);
                                    }
                                }
                                Err(e) => tracing::warn!("自动扫描 [{folder}] 失败: {e}"),
                            }
                        }
                        last_scan = Instant::now();
                    }

                    std::thread::sleep(Duration::from_millis(200));
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
                device_monitor: Mutex::new(None),
                device_monitor_stop: Arc::new(AtomicBool::new(false)),
                stream_handle: Mutex::new(None),
            });

            // 启动时恢复房间校正 IR（对齐移动端 applyDsp：文件丢失则清理脏路径）
            commands::room::restore_room_correction(app.handle());

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
            commands::playback::play_queue_at,
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
            commands::playback::session_interruption_began,
            commands::playback::session_interruption_ended,
            commands::playback::start_capture,
            commands::playback::stop_capture,
            commands::playback::is_capturing,
            commands::playback::set_crossfeed,
            commands::playback::set_noise_shaping,
            commands::playback::set_buffer_ms,
            commands::playback::set_replaygain_peak,
            commands::playback::read_audio_samples,
            commands::playback::enumerate_audio_devices,
            commands::playback::start_device_monitor,
            commands::playback::stop_device_monitor,
            commands::playback::set_audio_device_sync,
            commands::playback::set_auto_eq,
            commands::playback::list_auto_eq_profiles,
            commands::playback::set_dsd_mode,
            commands::playback::set_limiter_enabled,
            commands::playback::set_dither_enabled,
            commands::playback::set_output_sample_rate,
            commands::cue::parse_cue_file,
            commands::cue::parse_cue_text,
            commands::playlist_cmds::parse_playlist_file,
            commands::playlist_cmds::export_playlist_m3u,
            commands::playlist_cmds::export_playlist_pls,
            commands::playlist_cmds::export_playlist_auto,
            commands::stream_cmds::play_stream,
            commands::stream_cmds::stream_write,
            commands::stream_cmds::stream_eof,
            commands::stream_cmds::strm_fetch,
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
            commands::library::import_playlist,
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
            commands::probe::probe_sample_rate_cmd,
            commands::probe::probe_bit_depth_cmd,
            commands::probe::read_replaygain_tags,
            commands::probe::decide_output_cmd,
            commands::room::default_correction_config,
            commands::room::parse_rew_text,
            commands::room::generate_room_correction,
            commands::room::clear_room_correction,
            commands::room::get_room_correction_path,
            commands::utils::read_text_file,
            commands::utils::save_text_file,
            commands::nas_cmds::nas_list,
            commands::nas_cmds::nas_add,
            commands::nas_cmds::nas_remove,
            commands::nas_cmds::nas_mount,
            commands::nas_cmds::nas_unmount,
            commands::nas_cmds::nas_is_mounted,
            commands::subsonic_cmds::subsonic_get_config,
            commands::subsonic_cmds::subsonic_save_config,
            commands::subsonic_cmds::subsonic_test_connection,
            commands::subsonic_cmds::subsonic_scan,
            commands::subsonic_cmds::subsonic_search,
            commands::subsonic_cmds::subsonic_download_to_cache,
            commands::subsonic_cmds::subsonic_play,
            commands::webdav_cmds::webdav_get_config,
            commands::webdav_cmds::webdav_save_config,
            commands::webdav_cmds::webdav_test_connection,
            commands::webdav_cmds::webdav_list,
            commands::webdav_cmds::webdav_scan,
            commands::webdav_cmds::webdav_download_to_cache,
            commands::webdav_cmds::webdav_play,
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
