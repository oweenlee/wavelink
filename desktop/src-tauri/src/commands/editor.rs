use crate::state::AppState;
use sdk::library::{edit_audio_tags, LibraryDb, TagUpdate, Track};
use tauri::State;

#[tauri::command]
pub async fn edit_tags(
    path: String,
    update: TagUpdate,
    state: State<'_, AppState>,
) -> Result<Track, String> {
    let path_for_task = path.clone();
    let track = tauri::async_runtime::spawn_blocking(move || {
        edit_audio_tags(&path_for_task, &update).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| format!("edit task failed: {e}"))??;
    let db = state
        .library
        .lock()
        .map_err(|e| format!("lock failed: {e}"))?;
    db.upsert_track(&track)
        .map_err(|e| format!("db write failed: {e}"))?;
    Ok(track)
}

#[tauri::command]
pub fn delete_track(track_id: i64, state: State<AppState>) -> Result<(), String> {
    let db = state
        .library
        .lock()
        .map_err(|e| format!("lock failed: {e}"))?;
    db.remove_track(track_id)
        .map_err(|e| format!("delete failed: {e}"))?;
    Ok(())
}

#[tauri::command]
pub async fn batch_edit_tags(
    paths: Vec<String>,
    update: TagUpdate,
    state: State<'_, AppState>,
) -> Result<usize, String> {
    let db_path = state.db_path.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let db = LibraryDb::open(&db_path).map_err(|e| format!("db open failed: {e}"))?;
        let mut count = 0usize;
        for path in &paths {
            match edit_audio_tags(path, &update) {
                Ok(track) => {
                    if let Err(e) = db.upsert_track(&track) {
                        tracing::warn!("batch edit db write failed {path}: {e}");
                    }
                    count += 1;
                }
                Err(e) => tracing::warn!("batch edit failed {path}: {e}"),
            }
        }
        Ok(count)
    })
    .await
    .map_err(|e| format!("batch edit task failed: {e}"))?
}
