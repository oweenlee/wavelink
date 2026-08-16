/// 清理下载中断残留的 `.part` 文件（STRM / Subsonic / WebDAV 共用 `.cache` 子目录）
pub fn cleanup_part_files(data_dir: &std::path::Path) {
    let cache_dir = data_dir.join(".cache");
    let Ok(entries) = std::fs::read_dir(&cache_dir) else {
        return;
    };
    for sub in entries.flatten() {
        let dir = sub.path();
        if !dir.is_dir() {
            continue;
        }
        if let Ok(files) = std::fs::read_dir(&dir) {
            for file in files.flatten() {
                let path = file.path();
                if path.extension().and_then(|e| e.to_str()) == Some("part") {
                    let _ = std::fs::remove_file(&path);
                }
            }
        }
    }
}

/// 缓存总量上限（字节）：`.cache` 总大小超过后按最旧优先删除文件
const CACHE_MAX_BYTES: u64 = 4 * 1024 * 1024 * 1024; // 4 GiB

/// 缓存总量/LRU 管理：统计 `.cache` 各子目录总大小，超过阈值时按 mtime 从旧到新删除，
/// 直到低于阈值（保留已缓存完整文件，只清最旧；`.part` 由 cleanup_part_files 负责）。
pub fn cleanup_cache_oversize(data_dir: &std::path::Path) {
    let cache_dir = data_dir.join(".cache");
    let Ok(entries) = std::fs::read_dir(&cache_dir) else {
        return;
    };

    let mut files: Vec<(std::path::PathBuf, std::time::SystemTime, u64)> = Vec::new();
    let mut total: u64 = 0;
    for sub in entries.flatten() {
        let dir = sub.path();
        if !dir.is_dir() {
            continue;
        }
        if let Ok(inner) = std::fs::read_dir(&dir) {
            for file in inner.flatten() {
                let Ok(meta) = file.metadata() else { continue };
                if !meta.is_file() {
                    continue;
                }
                let len = meta.len();
                total = total.saturating_add(len);
                files.push((file.path(), meta.modified().unwrap_or(std::time::UNIX_EPOCH), len));
            }
        }
    }

    if total <= CACHE_MAX_BYTES || files.is_empty() {
        return;
    }
    // 最旧在前
    files.sort_by_key(|(_, mtime, _)| *mtime);
    let mut removed: u64 = 0;
    for (path, _, len) in files {
        if total.saturating_sub(removed) <= CACHE_MAX_BYTES {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            removed = removed.saturating_add(len);
            tracing::info!("缓存超限清理（保留最旧优先删除）: {}", path.display());
        }
    }
    if removed > 0 {
        tracing::info!("缓存清理完成：共释放 {} bytes（原 {} bytes）", removed, total);
    }
}

/// 窗口外观设置：Windows 深色标题栏 / macOS 透明标题栏
pub fn setup_window_appearance(window: &tauri::WebviewWindow) {
    #[cfg(target_os = "windows")]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        use windows_sys::Win32::Foundation::{BOOL, HWND};
        use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;

        unsafe {
            let Ok(handle) = window.window_handle() else {
                tracing::warn!("get window handle failed");
                return;
            };
            let RawWindowHandle::Win32(h) = handle.as_raw() else {
                return;
            };
            let hwnd: HWND = h.hwnd.get() as *mut std::ffi::c_void;
            let dark_mode: BOOL = 1;
            let _ = DwmSetWindowAttribute(
                hwnd,
                20,
                &dark_mode as *const _ as *const _,
                std::mem::size_of::<BOOL>() as u32,
            );
        }
    }
    #[cfg(target_os = "macos")]
    {
        let _ = window;
    }
}
