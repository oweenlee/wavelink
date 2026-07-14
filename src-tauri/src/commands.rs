use std::collections::HashMap;
use std::path::PathBuf;

use tauri::State;
use tauri::Emitter;

use sdk::dsp::{default_peq_bands, preset_bands, PeqBand, PresetName};
use sdk::library::{
    analyze_loudness as rg_analyze, edit_audio_tags, export_playlist,
    gain_for_loudness, get_file_cover, import_playlist, Scanner,
    AlbumBrief, TagUpdate, Track,
};
use sdk::{analyze_file, AnalysisResult, PlayMode};

use crate::state::AppState;

fn apply_replaygain(state: &AppState) {
    let rg = *state.replaygain_enabled.lock().expect("replaygain_enabled mutex 被毒化");
    if rg {
        if let Some(ref cur) = *state.current_track.lock().expect("current_track mutex 被毒化") {
            if let Ok(db) = state.library.lock() {
                if let Ok(tracks) = db.search(cur, 1, 0) {
                    if let Some(t) = tracks.first() {
                        if let Some(gain) = t.track_gain {
                            state.engine.set_replaygain_gain_db(gain as f32);
                            return;
                        }
                    }
                }
            }
        }
    }
    state.engine.set_replaygain_gain_db(0.0);
}

fn apply_track_settings(state: &AppState) {
    apply_replaygain(state);
    let base = *state.base_volume.lock().expect("base_volume mutex 被毒化");
    state.engine.set_volume(base as f32);
}

pub fn apply_replaygain_volume_for_path(path: &str, state: &AppState) {
    *state.current_track.lock().expect("current_track mutex 被毒化") = Some(path.to_string());
    apply_track_settings(state);
}

#[tauri::command]
pub fn play(path: String, state: State<AppState>) {
    *state.current_track.lock().expect("current_track mutex 被毒化") = Some(path.clone());
    apply_track_settings(&state);
    state.engine.play(path);
}

#[tauri::command]
pub fn play_queue(paths: Vec<String>, state: State<AppState>) {
    if let Some(first) = paths.first() {
        *state.current_track.lock().expect("current_track mutex 被毒化") = Some(first.clone());
    }
    apply_track_settings(&state);
    state.engine.play_queue(paths);
}

#[tauri::command]
pub fn next_track(state: State<AppState>) { state.engine.next_track(); }

#[tauri::command]
pub fn pause(state: State<AppState>) { state.engine.pause(); }

#[tauri::command]
pub fn resume(state: State<AppState>) { state.engine.resume(); }

#[tauri::command]
pub fn stop(state: State<AppState>) { state.engine.stop(); }

#[tauri::command]
pub fn seek(pos: f64, state: State<AppState>) { state.engine.seek(pos); }

#[tauri::command]
pub fn get_position(state: State<AppState>) -> f64 { state.engine.position_secs() }

#[tauri::command]
pub fn get_duration(state: State<AppState>) -> f64 { state.engine.duration_secs() }

#[tauri::command]
pub fn set_volume(vol: f64, state: State<AppState>) {
    *state.base_volume.lock().expect("base_volume mutex 被毒化") = vol;
    state.engine.set_volume(vol as f32);
}

#[tauri::command]
pub fn set_play_mode(mode: PlayMode, state: State<AppState>) {
    *state.play_mode.lock().expect("play_mode mutex 被毒化") = mode;
    state.engine.set_play_mode(mode);
}

#[tauri::command]
pub fn get_play_mode(state: State<AppState>) -> PlayMode {
    *state.play_mode.lock().expect("play_mode mutex 被毒化")
}

#[tauri::command]
pub fn remove_from_queue(idx: usize, state: State<AppState>) {
    state.engine.remove_from_queue(idx);
}

#[tauri::command]
pub fn set_stereo_widener(enabled: bool, width: f32, state: State<AppState>) {
    state.engine.set_stereo_widener(enabled, width);
}

#[tauri::command]
pub fn set_replaygain(enabled: bool, state: State<AppState>) {
    *state.replaygain_enabled.lock().expect("replaygain_enabled mutex 被毒化") = enabled;
    apply_track_settings(&state);
}

#[tauri::command]
pub fn get_replaygain(state: State<AppState>) -> bool {
    *state.replaygain_enabled.lock().expect("replaygain_enabled mutex 被毒化")
}

#[tauri::command]
pub fn analyze_replaygain(path: String, state: State<AppState>) -> Result<f64, String> {
    let lufs = rg_analyze(&PathBuf::from(&path))?;
    let gain = gain_for_loudness(lufs);
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.set_track_gain(&path, gain)
        .map_err(|e| format!("写入数据库失败: {e}"))?;
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
    let total = entries.len();
    let _ = app.emit("replaygain:start", serde_json::json!({ "total": total }));

    let app2 = app.clone();
    std::thread::spawn(move || {
        let mut completed = 0usize;
        let mut errors = 0usize;

        for (path, existing_gain) in &entries {
            if existing_gain.is_some() {
                completed += 1;
                continue;
            }
            match rg_analyze(&PathBuf::from(path)) {
                Ok(lufs) => {
                    let gain = gain_for_loudness(lufs);
                    if let Ok(db) = sdk::library::LibraryDb::open(&db_path) {
                        let _ = db.set_track_gain(path, gain);
                    }
                }
                Err(e) => {
                    tracing::warn!("分析失败 {path}: {e}");
                    errors += 1;
                }
            }
            completed += 1;
            let _ = app2.emit(
                "replaygain:progress",
                serde_json::json!({
                    "completed": completed, "total": total,
                    "current": path.split('/').last().unwrap_or("?"),
                }),
            );
        }
        let _ = app2.emit(
            "replaygain:done",
            serde_json::json!({
                "completed": completed, "errors": errors,
            }),
        );
    });
}

#[tauri::command]
pub fn analyze_track(path: String, state: State<AppState>) -> Result<AnalysisResult, String> {
    let result = analyze_file(&PathBuf::from(&path))?;
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
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
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
    let total = entries.len();
    let _ = app.emit("analysis:start", serde_json::json!({ "total": total }));

    let app2 = app.clone();
    std::thread::spawn(move || {
        let mut completed = 0usize;
        let mut errors = 0usize;

        for (track_id, path) in &entries {
            match analyze_file(&PathBuf::from(path)) {
                Ok(result) => {
                    if let Ok(db) = sdk::library::LibraryDb::open(&db_path) {
                        let _ =
                            db.set_analysis(*track_id, result.bpm, result.key.as_deref(), result.energy);
                    }
                }
                Err(e) => {
                    tracing::warn!("分析失败 {path}: {e}");
                    errors += 1;
                }
            }
            completed += 1;
            let _ = app2.emit(
                "analysis:progress",
                serde_json::json!({
                    "completed": completed, "total": total,
                    "current": path.split('/').last().unwrap_or("?"),
                }),
            );
        }
        let _ = app2.emit(
            "analysis:done",
            serde_json::json!({
                "completed": completed, "errors": errors,
            }),
        );
    });
}

#[tauri::command]
pub fn get_underrun_count(state: State<AppState>) -> u64 {
    state.engine.underrun_count()
}

#[tauri::command]
pub fn audio_info() -> serde_json::Value {
    serde_json::json!({
        "sample_rate": sdk::TARGET_SAMPLE_RATE,
        "channels": sdk::TARGET_CHANNELS,
    })
}

#[tauri::command]
pub fn save_text_file(path: String, content: String) -> Result<(), String> {
    std::fs::write(&path, &content).map_err(|e| format!("写入文件失败: {e}"))
}

#[tauri::command]
pub fn read_text_file(path: String) -> Result<String, String> {
    let bytes = std::fs::read(&path).map_err(|e| format!("读取文件失败: {e}"))?;
    if let Ok(s) = String::from_utf8(bytes.clone()) {
        return Ok(s);
    }
    use encoding_rs::GBK;
    let (cow, _, had_errors) = GBK.decode(&bytes);
    if had_errors {
        Err("文件编码不是 UTF-8 或 GBK".to_string())
    } else {
        Ok(cow.into_owned())
    }
}

#[tauri::command]
pub fn load_ir(path: String, state: State<AppState>) {
    state.engine.load_ir(path);
}

#[tauri::command]
pub fn clear_ir(state: State<AppState>) {
    state.engine.clear_ir();
}

#[tauri::command]
pub fn import_playlist_cmd(path: String) -> Result<Vec<String>, String> {
    import_playlist(&std::path::PathBuf::from(&path))
}

#[tauri::command]
pub fn export_playlist_cmd(path: String, entries: Vec<String>) -> Result<(), String> {
    export_playlist(&std::path::PathBuf::from(&path), &entries)
}

#[tauri::command]
pub fn scan_dir(path: String, state: State<AppState>) -> Result<serde_json::Value, String> {
    let dir = PathBuf::from(&path);
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    let result = Scanner::scan_directory(&db, &dir)?;
    Ok(serde_json::json!({
        "scanned": result.scanned,
        "errors": result.errors,
        "removed": result.removed,
    }))
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
pub fn edit_tags(path: String, update: TagUpdate, state: State<AppState>) -> Result<Track, String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    let track = edit_audio_tags(&path, &update)?;
    db.upsert_track(&track).map_err(|e| format!("写入数据库失败: {e}"))?;
    Ok(track)
}

#[tauri::command]
pub fn delete_track(track_id: i64, state: State<AppState>) -> Result<(), String> {
    let db = state.library.lock().map_err(|e| format!("锁失败: {e}"))?;
    db.remove_track(track_id).map_err(|e| format!("删除失败: {e}"))?;
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
            Err(e) => tracing::warn!("批量编辑失败 {path}: {e}"),
        }
    }
    Ok(count)
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
    get_file_cover(&p).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn lrc_lookup(artist: String, title: String, album: Option<String>) -> Result<Option<String>, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = do_lrc_lookup(&artist, &title, album.as_deref());
        let _ = tx.send(result);
    });
    match rx.recv_timeout(std::time::Duration::from_secs(15)) {
        Ok(result) => result,
        Err(_) => Err("查询超时".to_string()),
    }
}

fn do_lrc_lookup(artist: &str, title: &str, _album: Option<&str>) -> Result<Option<String>, String> {
    let artist = urlencoding(artist);
    let title = urlencoding(title);
    let url = format!(
        "https://lrclib.net/api/get?artist_name={}&track_name={}",
        artist, title
    );

    tracing::debug!("LRCLIB 请求: {}", url);
    let resp = ureq::get(&url)
        .header("User-Agent", "WaveLink/0.1.0 (music-player)")
        .call()
        .map_err(|e| {
            let msg = format!("LRCLIB 请求失败: {e}");
            tracing::error!("{}", msg);
            msg
        })?;

    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct LrcResponse {
        synced_lyrics: Option<String>,
        plain_lyrics: Option<String>,
    }

    let body: LrcResponse = resp.into_body().read_json().map_err(|e| {
        let msg = format!("LRCLIB 解析失败: {e}");
        tracing::error!("{}", msg);
        msg
    })?;
    tracing::info!("LRCLIB 查询成功: artist={}, title={}", artist, title);
    Ok(body.synced_lyrics.or(body.plain_lyrics))
}

fn urlencoding(s: &str) -> String {
    let mut result = String::new();
    for byte in s.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(*byte as char);
            }
            b' ' => result.push_str("%20"),
            b'&' => result.push_str("%26"),
            b'=' => result.push_str("%3D"),
            b'?' => result.push_str("%3F"),
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}

#[tauri::command]
pub fn get_eq_bands(state: State<AppState>) -> Result<Vec<PeqBand>, String> {
    let bands = state.peq_bands.lock().map_err(|e| format!("锁失败: {e}"))?;
    Ok(bands.clone())
}

#[tauri::command]
pub fn set_peq_band(
    index: usize,
    freq: f32,
    gain_db: f32,
    q: f32,
    state: State<AppState>,
) -> Result<(), String> {
    let mut bands = state.peq_bands.lock().map_err(|e| format!("锁失败: {e}"))?;
    if index < bands.len() {
        bands[index] = PeqBand { freq, gain_db, q };
        state.engine.set_peq_band(index, PeqBand { freq, gain_db, q });
    }
    Ok(())
}

#[tauri::command]
pub fn reset_eq(state: State<AppState>) -> Result<(), String> {
    let defaults = default_peq_bands();
    *state.peq_bands.lock().map_err(|e| format!("锁失败: {e}"))? = defaults.clone();
    for (i, band) in defaults.iter().enumerate() {
        state.engine.set_peq_band(i, band.clone());
    }
    Ok(())
}

#[tauri::command]
pub fn set_eq_preset(preset: PresetName, state: State<AppState>) -> Result<(), String> {
    let new_bands = preset_bands(preset);
    // 用 10 段预设值
    *state.peq_bands.lock().map_err(|e| format!("锁失败: {e}"))? = new_bands.clone();
    // 设置引擎 DSP：前 10 段用预设值，后 21 段清零（防止残留）
    for (i, band) in new_bands.iter().enumerate() {
        state.engine.set_peq_band(i, band.clone());
    }
    for i in 10..31 {
        state.engine.set_peq_band(i, PeqBand { freq: 0.0, gain_db: 0.0, q: 1.41 });
    }
    Ok(())
}

#[tauri::command]
pub fn set_engine_config(
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
    state: State<AppState>,
) {
    let cfg = sdk::EngineConfig {
        sample_rate,
        channels,
        buffer_ms,
        crossfade_ms: 0,
    };
    state.engine.set_config(cfg);
}

fn playlists_dir() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "无法获取 HOME 目录".to_string())?;
    #[cfg(target_os = "macos")]
    let dir = PathBuf::from(&home)
        .join("Music")
        .join("WaveLink")
        .join("playlists");
    #[cfg(not(target_os = "macos"))]
    let dir = PathBuf::from(&home).join(".wavelink").join("playlists");
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建播放列表目录失败: {e}"))?;
    Ok(dir)
}

#[tauri::command]
pub fn list_playlists() -> Result<Vec<String>, String> {
    let dir = playlists_dir()?;
    let mut names: Vec<String> = Vec::new();
    for entry in std::fs::read_dir(&dir).map_err(|e| format!("读取目录失败: {e}"))? {
        let entry = entry.map_err(|e| format!("读取条目失败: {e}"))?;
        let path = entry.path();
        if let Some(ext) = path.extension() {
            if ext == "m3u" || ext == "m3u8" || ext == "pls" {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    names.push(stem.to_string());
                }
            }
        }
    }
    names.sort();
    Ok(names)
}

#[tauri::command]
pub fn save_playlist(name: String, paths: Vec<String>) -> Result<(), String> {
    let dir = playlists_dir()?;
    let path = dir.join(format!("{}.m3u8", name));
    export_playlist(&path, &paths)
}

#[tauri::command]
pub fn load_playlist(name: String) -> Result<Vec<String>, String> {
    let dir = playlists_dir()?;
    for ext in &["m3u8", "m3u", "pls"] {
        let path = dir.join(format!("{}.{}", name, ext));
        if path.exists() {
            return import_playlist(&path);
        }
    }
    Err(format!("播放列表 '{name}' 未找到"))
}

#[tauri::command]
pub fn delete_playlist(name: String) -> Result<(), String> {
    let dir = playlists_dir()?;
    for ext in &["m3u8", "m3u", "pls"] {
        let path = dir.join(format!("{}.{}", name, ext));
        if path.exists() {
            std::fs::remove_file(&path)
                .map_err(|e| format!("删除播放列表失败: {e}"))?;
            return Ok(());
        }
    }
    Err(format!("播放列表 '{name}' 未找到"))
}
