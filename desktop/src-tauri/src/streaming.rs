//! 边下边播：STRM http(s) URL → core 流式解码（首块即出声）＋并行写 `.part` 缓存
//!
//! 对齐 mobile `smb.rs::engine_play_smb_stream` 模式：启动 core `play_stream`
//! 拿到 StreamHandle → 后台喂流线程从网络读分块喂 core（同时追加写
//! `.cache/strm/*.part`）→ 播完 signal_eof 并 rename 成正式缓存（下次秒开）；
//! 流被关闭（切歌 / stop / seek 重启，`handle.write` 返回 0）时退出并清理残留。
//!
//! 网络获取、缓存管理留在宿主层（core 只按 feed 流消费），与 mobile 同一内核。

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use tauri::{AppHandle, Manager};

use crate::state::AppState;
use crate::commands::lock_or_die;

/// STRM URL 缓存文件可识别的音频扩展名（与 strm_fetch 规则一致）
const CACHE_AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "aac", "m4a", "m4b", "mp4", "wma", "dsf", "dff", "ape", "opus",
    "aiff", "aif", "wv",
];

/// 计算 STRM URL 的缓存相对路径：md5(url) + sanitize(name)[.ext]，与 strm_fetch 一致。
/// 返回 (final, part, legacy_noext)；legacy 兼容旧版本无扩展名缓存。
pub fn cache_rel_paths(url: &str, name: &str) -> Result<(PathBuf, PathBuf, PathBuf), String> {
    let hash = {
        use md5::{Digest, Md5};
        use std::fmt::Write as _;
        let mut h = Md5::new();
        h.update(url.as_bytes());
        let mut out = String::with_capacity(32);
        for b in h.finalize() {
            let _ = write!(out, "{b:02x}");
        }
        out
    };
    let safe_name: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let safe_name = safe_name.trim().trim_matches('.');
    let safe_name = if safe_name.is_empty() {
        "remote".to_string()
    } else {
        safe_name.to_string()
    };
    let ext = url
        .split('?')
        .next()
        .and_then(|p| p.rsplit('.').next())
        .map(|e| e.to_lowercase())
        .filter(|e| CACHE_AUDIO_EXTENSIONS.contains(&e.as_str()));
    let final_rel = match &ext {
        Some(e) => PathBuf::from(format!("{hash}_{safe_name}.{e}")),
        None => PathBuf::from(format!("{hash}_{safe_name}")),
    };
    Ok((
        final_rel,
        PathBuf::from(format!("{hash}_{safe_name}.part")),
        PathBuf::from(format!("{hash}_{safe_name}")),
    ))
}

/// 中止当前活跃流（take + eof）：喂流线程感知 `write` 返回 0 后自行退出清理。
/// 所有本地播放入口（play/play_queue/play_queue_at/stop）都必须先调用，
/// 否则旧句柄残留会让 seek 误判「流模式」。
pub fn cancel_active_stream(state: &AppState) {
    if let Some(sh) = state.stream_handle.lock().unwrap().take() {
        sh.signal_eof();
    }
}

/// 完整缓存命中（非空 final 或 legacy 无扩展名路径）
fn cache_hit(cache_dir: &Path, final_rel: &Path, legacy_rel: &Path) -> Option<PathBuf> {
    for rel in [final_rel, legacy_rel] {
        let p = cache_dir.join(rel);
        if let Ok(meta) = std::fs::metadata(&p) {
            if meta.len() > 0 {
                return Some(p);
            }
        }
    }
    None
}

/// STRM URL 播放入口（同步阻塞版，须在 spawn_blocking 中调用）：
/// 1. 完整缓存 → 本地播放（走标准引擎管线，可 seek）；
/// 2. 否则 GET → 首块即 feed → 后台线程边下边播边写缓存。
/// 返回实际担任「当前曲目标识」的路径：本地缓存路径，或流式占位 "stream"
/// （对应 core 发出的 TrackChanged("stream")）。
fn play_remote_impl(
    app: &AppHandle,
    state: &AppState,
    url: &str,
    name: &str,
    format_hint: Option<String>,
) -> Result<String, String> {
    let cache_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join(".cache")
        .join("strm");
    std::fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;
    let (final_rel, part_rel, legacy_rel) = cache_rel_paths(url, name)?;
    let final_path = cache_dir.join(&final_rel);
    let part_path = cache_dir.join(&part_rel);

    // 1. 完整缓存：本地播放
    if let Some(cached) = cache_hit(&cache_dir, &final_rel, &legacy_rel) {
        cancel_active_stream(state);
        *lock_or_die(&state.current_track) = Some(cached.to_string_lossy().to_string());
        *lock_or_die(&state.stream_source) = None;
        state.engine.play(cached.to_string_lossy().to_string());
        tracing::info!("STRM 缓存命中，本地播放: {}", cached.display());
        return Ok(cached.to_string_lossy().to_string());
    }

    // 2. 流式：直接 GET（strm URL 通常自带认证 query）
    let client = crate::remote::http_client()?;
    let resp = client
        .get(url)
        .header(reqwest::header::ACCEPT_ENCODING, "identity")
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }
    let total = resp.content_length();

    // 掐断旧流（换源/重复播放时，旧喂流线程经 write 返回 0 退出）
    cancel_active_stream(state);

    let handle = state
        .engine
        .play_stream(format_hint.clone(), total)
        .map_err(|e| e.to_string())?;
    *lock_or_die(&state.stream_handle) = Some(handle.clone());
    *lock_or_die(&state.stream_source) = Some((url.to_string(), name.to_string(), format_hint));

    // 后台喂流线程：网络读 → feed core + 写 .part；完整后 rename 正式缓存。
    let handle_thread = handle.clone();
    let part_thread = part_path.clone();
    let final_thread = final_path.clone();
    std::thread::spawn(move || {
        match feed_stream(handle_thread, resp, &part_thread, &final_thread) {
            Ok(()) => {}
            Err(e) => {
                tracing::warn!("STRM 流结束（未完整缓存）: {e}");
            }
        }
    });

    Ok("stream".to_string())
}

/// 喂流线程体：读响应体分块 → 喂 core + 追加写 `.part`；完整写完后
/// signal_eof + rename 正式缓存。`write` 返回 0（解码端已关/切歌）→ 丢弃部分缓存。
fn feed_stream(
    handle: sdk::stream::StreamHandle,
    mut resp: reqwest::blocking::Response,
    part_path: &Path,
    final_path: &Path,
) -> Result<(), String> {
    let mut file = std::fs::File::create(part_path).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 64 * 1024];
    let mut written_total: u64 = 0;
    loop {
        let n = resp.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        written_total += n as u64;
        // 背压：缓冲满时阻塞直到解码消费；解码端关闭返回 0
        if handle.write(&buf[..n]) == 0 {
            drop(file);
            let _ = std::fs::remove_file(part_path);
            return Err("stream closed".into());
        }
    }
    file.flush().map_err(|e| e.to_string())?;
    drop(file);
    handle.signal_eof();

    // 完整缓存落盘（Windows rename 不覆盖已存在文件：先清 0 字节目标）
    if std::fs::metadata(final_path)
        .map(|m| m.len() == 0)
        .unwrap_or(false)
    {
        let _ = std::fs::remove_file(final_path);
    }
    std::fs::rename(part_path, final_path).map_err(|e| e.to_string())?;
    tracing::info!(
        "STRM 流缓存完成: {} ({} bytes)",
        final_path.display(),
        written_total
    );
    Ok(())
}

/// 流式播放中 seek：引擎流无 seek 能力（无 current_entry），且字节偏移无法从
/// 秒数可靠换算 → 重新发起播放。缓存若已完整则自然走本地播放（从头）。
pub fn restart_stream(app: &AppHandle, state: &AppState) {
    let src = lock_or_die(&state.stream_source).clone();
    if let Some((url, name, hint)) = src {
        let app = app.clone();
        std::thread::spawn(move || {
            if let Some(state) = app.try_state::<AppState>() {
                let _ = play_remote_impl(&app, &state, &url, &name, hint);
            }
        });
    }
}

/// STRM URL 播放（前端命令入口）：后台线程执行首块抓取与缓存判断，避免阻塞主线程。
#[tauri::command]
pub async fn play_remote(
    url: String,
    name: String,
    format_hint: Option<String>,
    app: AppHandle,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app
            .try_state::<AppState>()
            .ok_or("app state not ready")?;
        play_remote_impl(&app, &state, &url, &name, format_hint)
    })
    .await
    .map_err(|e| format!("stream task failed: {e}"))?
}

/// 流式播放当前源信息（供系统媒体控制展示曲名等）
pub fn active_stream_name(state: &AppState) -> Option<String> {
    lock_or_die(&state.stream_source)
        .as_ref()
        .map(|(_, name, _)| name.clone())
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_rel_paths_stable_and_ext() {
        let (final_p, part_p, legacy_p) =
            cache_rel_paths("http://nas/music/01.mp3?token=abc", "Song 名").unwrap();
        let final_s = final_p.to_string_lossy().to_string();
        let part_s = part_p.to_string_lossy().to_string();
        let legacy_s = legacy_p.to_string_lossy().to_string();

        // 扩展名来自 URL（过滤 query）；非 ASCII 字符 sanitize 为 _（与 strm_fetch 一致）
        assert!(final_s.ends_with("_Song _.mp3"), "final={final_s}");
        // part = 无扩展名 + .part；legacy = 无扩展名（兼容旧缓存命中）
        assert_eq!(part_s, format!("{legacy_s}.part"));
        assert_eq!(legacy_p.extension(), None);
        // md5 前缀固定 32 位 hex（跨 Rust 版本稳定，避免旧缓存全部失效）
        let hash = final_s.split('_').next().unwrap();
        assert_eq!(hash.len(), 32);
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_cache_rel_paths_sanitize_and_noext() {
        let (final_p, _, _) = cache_rel_paths("http://x/y.mp3", "  A/B:C*D?  ").unwrap();
        let name = final_p.to_string_lossy().to_string();
        assert!(!name.contains('/') && !name.contains(':') && !name.contains('?'));
        // URL 无音频扩展名 → 不加 ext
        let (final_p, _, _) = cache_rel_paths("http://x/stream", "t").unwrap();
        assert_eq!(final_p.extension(), None);
    }
}
