use super::lock_or_die;
use crate::state::AppState;
use std::path::Path;
use tauri::{AppHandle, Manager, State};

/// 开始流式播放（网络流媒体）
/// 返回 true 表示启动成功
#[tauri::command]
pub fn play_stream(
    format_hint: Option<String>,
    content_length: Option<u64>,
    state: State<AppState>,
) -> Result<(), String> {
    let handle = state
        .engine
        .play_stream(format_hint, content_length)
        .map_err(|e| e.to_string())?;
    crate::streaming::cancel_active_stream(&state);
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

    // 缓存路径规则与 streaming::play_remote 共用（md5(url) + safe_name + ext）
    let (final_rel, part_rel, legacy_rel) = crate::streaming::cache_rel_paths(url, name)?;
    let final_path = cache_dir.join(&final_rel);
    let part_path = cache_dir.join(&part_rel);
    let legacy_path = cache_dir.join(&legacy_rel);

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

    let mut file = std::fs::File::create(&part_path).map_err(|e| e.to_string())?;
    {
        use std::io::Write;
        std::io::copy(&mut resp, &mut file).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
    }
    drop(file);

    if std::fs::metadata(&part_path)
        .map(|m| m.len() == 0)
        .unwrap_or(true)
    {
        let _ = std::fs::remove_file(&part_path);
        return Err(format!("下载为空文件: {url}"));
    }
    // Windows 下 rename 不会覆盖已存在文件；目标只可能是残留的 0 字节文件，先清掉
    if std::fs::metadata(&final_path)
        .map(|m| m.len() == 0)
        .unwrap_or(false)
    {
        let _ = std::fs::remove_file(&final_path);
    }
    std::fs::rename(&part_path, &final_path).map_err(|e| e.to_string())?;

    Ok(final_path.to_string_lossy().to_string())
}

