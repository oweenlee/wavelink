use std::path::PathBuf;
use sdk::playlist::{parse_playlist, export_m3u, export_pls, export_playlist, PlaylistEntry};

#[tauri::command]
pub fn parse_playlist_file(path: String) -> Result<Vec<PlaylistEntry>, String> {
    parse_playlist(&PathBuf::from(&path))
}

#[tauri::command]
pub fn export_playlist_m3u(path: String, entries: Vec<PlaylistEntry>) -> Result<(), String> {
    export_m3u(&PathBuf::from(&path), &entries)
}

#[tauri::command]
pub fn export_playlist_pls(path: String, entries: Vec<PlaylistEntry>) -> Result<(), String> {
    export_pls(&PathBuf::from(&path), &entries)
}

#[tauri::command]
pub fn export_playlist_auto(path: String, entries: Vec<PlaylistEntry>) -> Result<(), String> {
    export_playlist(&PathBuf::from(&path), &entries)
}
