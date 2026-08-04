use tauri::State;
use sdk::library::{edit_audio_tags, TagUpdate, Track};
use crate::state::AppState;

#[tauri::command]
pub fn edit_tags(path: String, update: TagUpdate, state: State<AppState>) -> Result<Track, String> {
    let db = state.library.lock().map_err(|e| format!("lock failed: {e}"))?;
    let track = edit_audio_tags(&path, &update)?;
    db.upsert_track(&track).map_err(|e| format!("db write failed: {e}"))?;
    Ok(track)
}

#[tauri::command]
pub fn delete_track(track_id: i64, state: State<AppState>) -> Result<(), String> {
    let db = state.library.lock().map_err(|e| format!("lock failed: {e}"))?;
    db.remove_track(track_id).map_err(|e| format!("delete failed: {e}"))?;
    Ok(())
}

#[tauri::command]
pub fn batch_edit_tags(
    paths: Vec<String>,
    update: TagUpdate,
    state: State<AppState>,
) -> Result<usize, String> {
    let mut count = 0usize;
    for path in &paths {
        match edit_audio_tags(path, &update) {
            Ok(track) => {
                if let Ok(db) = state.library.lock() {
                    let _ = db.upsert_track(&track);
                }
                count += 1;
            }
            Err(e) => tracing::warn!("batch edit failed {path}: {e}"),
        }
    }
    Ok(count)
}
