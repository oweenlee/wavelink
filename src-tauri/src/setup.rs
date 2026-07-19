/// 窗口外观设置：Windows 深色标题栏 / macOS 透明标题栏
pub fn setup_window_appearance(window: &tauri::WebviewWindow) {
    #[cfg(target_os = "windows")]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;
        use windows_sys::Win32::Foundation::{BOOL, HWND};

        unsafe {
            let Ok(handle) = window.window_handle() else {
                tracing::warn!("获取窗口句柄失败");
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
