use crate::state::AppState;
use sdk::library::{analyze_loudness as rg_analyze, gain_for_loudness};
use sdk::{analyze_file, AnalysisResult};
use std::collections::HashMap;
use std::path::PathBuf;
use tauri::Emitter;
use tauri::State;

/// 批量处理辅助：遍历条目，发进度事件，返回完成数
fn batch_process<T, F>(entries: Vec<T>, app: &tauri::AppHandle, event_prefix: &str, process: F)
where
    F: Fn(&T) -> Result<(), String>,
{
    let total = entries.len();
    let _ = app.emit(
        &format!("{event_prefix}:start"),
        serde_json::json!({ "total": total }),
    );

    let mut completed = 0usize;
    let mut errors = 0usize;

    for entry in &entries {
        if let Err(e) = process(entry) {
            tracing::warn!("analysis failed: {e}");
            errors += 1;
        }
        completed += 1;
        let _ = app.emit(
            &format!("{event_prefix}:progress"),
            serde_json::json!({
                "completed": completed, "total": total,
            }),
        );
    }
    let _ = app.emit(
        &format!("{event_prefix}:done"),
        serde_json::json!({ "completed": completed, "errors": errors }),
    );
}

#[tauri::command]
pub async fn analyze_replaygain(path: String, state: State<'_, AppState>) -> Result<f64, String> {
    let path_for_task = path.clone();
    let gain = tauri::async_runtime::spawn_blocking(move || {
        let lufs = rg_analyze(&PathBuf::from(&path_for_task))?;
        Ok::<f64, String>(gain_for_loudness(lufs))
    })
    .await
    .map_err(|e| format!("analysis task failed: {e}"))??;
    let db = state
        .library
        .lock()
        .map_err(|e| format!("lock failed: {e}"))?;
    db.set_track_gain(&path, gain)
        .map_err(|e| format!("db write failed: {e}"))?;
    Ok(gain)
}

#[tauri::command]
pub fn analyze_all_replaygain(app: tauri::AppHandle, state: State<AppState>) {
    let db_path = state.db_path.clone();
    let entries: Vec<(String, Option<f64>)> = state
        .library
        .lock()
        .ok()
        .and_then(|db| db.all_tracks(i64::MAX, 0).ok())
        .unwrap_or_default()
        .into_iter()
        .map(|t| (t.path, t.track_gain))
        .collect();

    std::thread::spawn(move || {
        let to_analyze: Vec<&(String, Option<f64>)> =
            entries.iter().filter(|(_, g)| g.is_none()).collect();
        batch_process(to_analyze, &app, "replaygain", |(path, _)| {
            let lufs = rg_analyze(&PathBuf::from(path))?;
            let gain = gain_for_loudness(lufs);
            let db =
                sdk::library::LibraryDb::open(&db_path).map_err(|e| format!("db open: {e}"))?;
            db.set_track_gain(path, gain)
                .map_err(|e| format!("db write: {e}"))
        });
    });
}

#[tauri::command]
pub async fn analyze_track(
    path: String,
    state: State<'_, AppState>,
) -> Result<AnalysisResult, String> {
    let path_for_task = path.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        analyze_file(&PathBuf::from(&path_for_task)).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| format!("analysis task failed: {e}"))??;
    if let Ok(db) = state.library.lock() {
        let track_id: Option<i64> = db
            .search(&path, 1, 0)
            .ok()
            .and_then(|t| t.first().map(|t| t.id));
        if let Some(id) = track_id {
            let _ = db.set_analysis(id, result.bpm, result.key.as_deref(), result.energy);
        }
    }
    Ok(result)
}

#[tauri::command]
pub fn get_track_analyses(
    track_ids: Vec<i64>,
    state: State<AppState>,
) -> Result<HashMap<i64, AnalysisResult>, String> {
    let db = state
        .library
        .lock()
        .map_err(|e| format!("lock failed: {e}"))?;
    db.get_analyses(&track_ids).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn analyze_all_tracks(app: tauri::AppHandle, state: State<AppState>) {
    let db_path = state.db_path.clone();
    let entries: Vec<(i64, String)> = state
        .library
        .lock()
        .ok()
        .and_then(|db| db.all_tracks(i64::MAX, 0).ok())
        .unwrap_or_default()
        .into_iter()
        .map(|t| (t.id, t.path))
        .collect();

    std::thread::spawn(move || {
        batch_process(entries, &app, "analysis", |(track_id, path)| {
            let result = analyze_file(&PathBuf::from(path))?;
            let db =
                sdk::library::LibraryDb::open(&db_path).map_err(|e| format!("db open: {e}"))?;
            db.set_analysis(*track_id, result.bpm, result.key.as_deref(), result.energy)
                .map_err(|e| format!("db write: {e}"))
        });
    });
}
