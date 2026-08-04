use std::path::PathBuf;
use sdk::{parse_cue, parse_cue_str, CueSheet};

#[tauri::command]
pub fn parse_cue_file(path: String) -> Result<CueSheet, String> {
    parse_cue(&PathBuf::from(&path))
}

#[tauri::command]
pub fn parse_cue_text(data: String) -> Result<CueSheet, String> {
    parse_cue_str(&data)
}
