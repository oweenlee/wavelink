use std::path::Path;
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

/// 纯下载：把 STRM http(s) URL 内容下载到本地缓存并返回本地路径。
/// 不触发引擎播放——仅用于解析队列中 URL 轨道为本地路径（由前端统一
/// play_queue 交给引擎），避免队列含 N 首 URL 时产生 N+1 次播放切换。
/// 缓存命中（非空文件）时直接返回，不重新下载。
#[tauri::command]
pub async fn strm_fetch(url: String, name: String, app: AppHandle) -> Result<String, String> {
    let cache_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join(".cache")
        .join("strm");
    // 阻塞 HTTP 下载放到后台线程，避免同步 command 卡死主线程（与 scan_dir 同理）
    tauri::async_runtime::spawn_blocking(move || strm_fetch_blocking(&url, &name, &cache_dir))
        .await
        .map_err(|e| format!("strm fetch task failed: {e}"))?
}

fn strm_fetch_blocking(url: &str, name: &str, cache_dir: &Path) -> Result<String, String> {
    std::fs::create_dir_all(cache_dir).map_err(|e| e.to_string())?;

    // 使用 md5 而非 DefaultHasher：后者不保证跨 Rust 版本稳定，会导致旧缓存全部失效
    let hash = {
        use md5::{Digest, Md5};
        let mut h = Md5::new();
        h.update(url.as_bytes());
        hex_encode(&h.finalize())
    };
    let safe_name: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') { c } else { '_' })
        .collect();
    let safe_name = safe_name.trim().trim_matches('.');
    let safe_name = if safe_name.is_empty() { "remote".to_string() } else { safe_name.to_string() };

    // 缓存文件带音频扩展名，给 Symphonia 更可靠的格式 hint。
    // 旧版本缓存文件没有扩展名，仍兼容命中。
    let ext = url
        .split('?')
        .next()
        .and_then(|p| p.rsplit('.').next())
        .map(|e| e.to_lowercase())
        .filter(|e| STRM_CACHE_AUDIO_EXTENSIONS.contains(&e.as_str()));
    let final_path = match &ext {
        Some(ext) => cache_dir.join(format!("{hash}_{safe_name}.{ext}")),
        None => cache_dir.join(format!("{hash}_{safe_name}")),
    };
    let legacy_path = cache_dir.join(format!("{hash}_{safe_name}"));

    for path in [&final_path, &legacy_path] {
        if let Ok(meta) = std::fs::metadata(path) {
            if meta.len() > 0 {
                return Ok(path.to_string_lossy().to_string());
            }
        }
    }

    // 直接 GET（strm URL 通常自带认证 query，无需 Digest/Basic 协商）
    let client = crate::remote::http_client()?;
    let mut resp = client
        .get(url)
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
    // Windows 下 rename 不会覆盖已存在文件；目标只可能是残留的 0 字节文件，先清掉
    if std::fs::metadata(&final_path).map(|m| m.len() == 0).unwrap_or(false) {
        let _ = std::fs::remove_file(&final_path);
    }
    std::fs::rename(&part_path, &final_path).map_err(|e| e.to_string())?;

    Ok(final_path.to_string_lossy().to_string())
}

/// 单曲直播 STRM http(s) URL：先下载到本地缓存，再交给引擎立即播放。
/// 适用于「立即播放单个 URL」场景（命令内部直接 play，不建队列）。
#[tauri::command]
pub async fn strm_play(
    url: String,
    name: String,
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let final_str = strm_fetch(url, name, app).await?;

    *lock_or_die(&state.current_track) = Some(final_str.clone());
    crate::commands::apply_track_settings(&state);
    state.engine.play(final_str.clone());
    Ok(final_str)
}

/// STRM URL 缓存文件可识别的音频扩展名（与 library scanner 保持一致）
const STRM_CACHE_AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "aac", "m4a", "m4b", "mp4",
    "wma", "dsf", "dff", "ape", "opus", "aiff", "aif", "wv",
];

fn hex_encode(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(out, "{b:02x}");
    }
    out
}
