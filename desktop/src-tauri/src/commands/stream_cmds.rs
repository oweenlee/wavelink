use tauri::{AppHandle, Manager, State};
use crate::state::AppState;
use super::lock_or_die;

/// 开始流式播放（网络流媒体）
/// 返回 true 表示启动成功
#[tauri::command]
pub fn play_stream(
    format_hint: Option<String>,
    content_length: Option<u64>,
    state: State<AppState>,
) -> Result<(), String> {
    let handle = state.engine.play_stream(format_hint, content_length).map_err(|e| e.to_string())?;
    *lock_or_die(&state.stream_handle) = Some(handle);
    Ok(())
}

/// 向流式播放写入音频数据
/// 返回实际写入的字节数
#[tauri::command]
pub fn stream_write(data: Vec<u8>, state: State<AppState>) -> usize {
    let guard = lock_or_die(&state.stream_handle);
    match guard.as_ref() {
        Some(sh) => sh.write(&data),
        None => 0,
    }
}

/// 通知流式播放数据结束
#[tauri::command]
pub fn stream_eof(state: State<AppState>) {
    if let Some(sh) = lock_or_die(&state.stream_handle).take() {
        sh.signal_eof();
    }
}

/// 播放 STRM http(s) URL 曲目：下载到本地缓存后交给引擎播放。
/// 引擎只接受本地路径，故复用「下载缓存再 play」链路（与 Subsonic/WebDAV 一致）。
/// 返回本地缓存路径。
#[tauri::command]
pub fn strm_play(
    url: String,
    name: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let cache_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join(".cache")
        .join("strm");
    std::fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;

    let hash = {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut h = DefaultHasher::new();
        url.hash(&mut h);
        format!("{:016x}", h.finish())
    };
    let safe_name: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') { c } else { '_' })
        .collect();
    let safe_name = safe_name.trim().trim_matches('.');
    let safe_name = if safe_name.is_empty() { "remote".to_string() } else { safe_name.to_string() };
    let final_path = cache_dir.join(format!("{hash}_{safe_name}"));
    let final_str = final_path.to_string_lossy().to_string();

    // 缓存命中（非空文件）
    if let Ok(meta) = std::fs::metadata(&final_path) {
        if meta.len() > 0 {
            return Ok(final_str);
        }
    }

    // 直接 GET（strm URL 通常自带认证 query，无需 Digest/Basic 协商）
    let client = crate::remote::http_client()?;
    let mut resp = client
        .get(&url)
        .header(reqwest::header::ACCEPT_ENCODING, "identity")
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }

    let part_path = cache_dir.join(format!("{hash}_{safe_name}.part"));
    let mut file = std::fs::File::create(&part_path).map_err(|e| e.to_string())?;
    {
        use std::io::Write;
        std::io::copy(&mut resp, &mut file).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
    }
    drop(file);

    if std::fs::metadata(&part_path).map(|m| m.len() == 0).unwrap_or(true) {
        let _ = std::fs::remove_file(&part_path);
        return Err(format!("下载为空文件: {url}"));
    }
    std::fs::rename(&part_path, &final_path).map_err(|e| e.to_string())?;

    *lock_or_die(&state.current_track) = Some(final_str.clone());
    crate::commands::apply_track_settings(&state);
    state.engine.play(final_str.clone());
    Ok(final_str)
}
