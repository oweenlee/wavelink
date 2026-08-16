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
