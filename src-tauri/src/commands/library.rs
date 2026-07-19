use std::path::PathBuf;
use tauri::State;
use sdk::library::{Scanner, Track, AlbumBrief};
use crate::state::AppState;

#[tauri::command]
pub fn scan_dir(path: String, state: State<AppState>) -> Result<serde_json::Value, String> {
    let dir = PathBuf::from(&path);
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    let result = Scanner::scan_directory(&db, &dir)?;
    db.add_folder(&path).ok();
    Ok(serde_json::json!({
        "scanned": result.scanned,
        "errors": result.errors,
        "removed": result.removed,
    }))
}

#[tauri::command]
pub fn get_scan_folders(state: State<AppState>) -> Result<Vec<String>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.list_folders().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn remove_scan_folder(path: String, state: State<AppState>) -> Result<usize, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    let removed = db.remove_folder(&path).map_err(|e| e.to_string())?;
    Ok(removed.len())
}

#[tauri::command]
pub fn search_tracks(
    keyword: String,
    limit: i64,
    offset: i64,
    state: State<AppState>,
) -> Result<Vec<Track>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.search(&keyword, limit, offset).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_tracks(limit: i64, offset: i64, state: State<AppState>) -> Result<Vec<Track>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.all_tracks(limit, offset).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_artists(state: State<AppState>) -> Result<Vec<String>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.artists().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_albums_by_artist(artist: String, state: State<AppState>) -> Result<Vec<String>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.albums_by_artist(&artist).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_tracks_by_album(
    artist: String,
    album: String,
    state: State<AppState>,
) -> Result<Vec<Track>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.tracks_by_album(&artist, &album).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_all_albums(state: State<AppState>) -> Result<Vec<AlbumBrief>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.all_albums().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_track_count(state: State<AppState>) -> Result<i64, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.track_count().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_cover(track_id: i64, state: State<AppState>) -> Result<Option<String>, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.get_cover(track_id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_file_cover_cmd(path: String) -> Result<Option<String>, String> {
    let p = std::path::PathBuf::from(&path);
    sdk::library::get_file_cover(&p).map_err(|e| e.to_string())
}

/// 清空数据库所有数据并重建
#[tauri::command]
pub fn reset_database(state: State<AppState>) -> Result<(), String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.reset_database().map_err(|e| format!("重置数据库失败: {e}"))
}
