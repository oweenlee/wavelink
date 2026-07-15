// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod logging;
mod media_bridge;
mod nas;
mod settings;
mod state;
mod tray;

use std::sync::Mutex;

use crossbeam_channel::Receiver;
use tauri::{Emitter, Manager};

use sdk::dsp::default_peq_bands;
use sdk::library::LibraryDb;
use sdk::{EngineEvent, EngineHandle, PlayMode};

use nas::NasManager;
use state::AppState;

/// 设置 Windows 标题栏为深色模式，macOS 标题栏透明，以匹配深色玻璃 UI
fn setup_window_appearance(window: &tauri::WebviewWindow) {
#[cfg(target_os = "windows")]
{
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;
    use windows_sys::Win32::Foundation::{BOOL, HWND};

    unsafe {
        let Ok(handle) = window.window_handle() else {
            tracing::warn!("获取窗口句柄失败");
            return;
        };
        let RawWindowHandle::Win32(h) = handle.as_raw() else {
            return;
        };
        let hwnd: HWND = h.hwnd.get() as *mut std::ffi::c_void;
        let dark_mode: BOOL = 1;
        let _ = DwmSetWindowAttribute(
            hwnd,
            20,  // DWMWA_USE_IMMERSIVE_DARK_MODE
            &dark_mode as *const _ as *const _,
            std::mem::size_of::<BOOL>() as u32,
        );
    }
}
    #[cfg(target_os = "macos")]
    {
        // macOS 通过 tauri.conf.json 的 titleBarStyle: Transparent 处理
        let _ = window;
    }
}

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

                        // 更新系统媒体控制
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

            let media_bridge = media_bridge::MediaBridge::new();
            let nas_manager = NasManager::new(&db_path);

            // 自动挂载标记为 auto_mount 的 NAS 连接
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
                setup_window_appearance(&window);

                // 关闭窗口时隐藏到托盘而非退出
                let handle = app.handle().clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        let _ = handle.get_webview_window("main").map(|w| w.hide());
                    }
                });

                // macOS: Dock 图标点击时恢复窗口（在 .run() 中处理）
            }

            // 创建系统托盘
            if let Err(e) = tray::create_tray(app.handle()) {
                tracing::warn!("创建系统托盘失败: {e}");
            }

            // 全局快捷键（macOS 媒体键由 MPRemoteCommandCenter 处理）
            #[cfg(not(target_os = "macos"))]
            {
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
            commands::get_underrun_count,
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
            commands::get_scan_folders,
            commands::remove_scan_folder,
            commands::reset_database,
            commands::search_tracks,
            commands::edit_tags,
            commands::delete_track,
            commands::batch_edit_tags,
            commands::get_tracks,
            commands::get_artists,
            commands::get_albums_by_artist,
            commands::get_tracks_by_album,
            commands::get_all_albums,
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
            commands::nas_list,
            commands::nas_add,
            commands::nas_remove,
            commands::nas_mount,
            commands::nas_unmount,
            commands::nas_is_mounted,
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
                    // 窗口已销毁，重建
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
