//! 设置持久化 — 保存/加载 JSON 设置文件

use std::collections::HashMap;
use std::path::PathBuf;

/// 获取设置文件路径
fn settings_path() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    let base = {
        let home = std::env::var("HOME").ok()?;
        PathBuf::from(&home)
            .join("Library")
            .join("Application Support")
            .join("com.wavelink.app")
    };
    #[cfg(target_os = "windows")]
    let base = {
        let appdata = std::env::var("APPDATA").ok()?;
        PathBuf::from(appdata).join("com.wavelink.app")
    };
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let base = {
        let home = std::env::var("HOME").ok()?;
        PathBuf::from(&home).join(".wavelink")
    };

    std::fs::create_dir_all(&base).ok()?;
    Some(base.join("settings.json"))
}

/// 保存设置
#[tauri::command]
pub fn save_settings(settings: HashMap<String, serde_json::Value>) -> Result<(), String> {
    let path = settings_path().ok_or("cannot get settings path")?;
    let json = serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?;
    std::fs::write(&path, json).map_err(|e| format!("write settings failed: {e}"))?;
    tracing::info!("settings saved to: {}", path.display());
    Ok(())
}

/// 加载设置
#[tauri::command]
pub fn load_settings() -> Result<HashMap<String, serde_json::Value>, String> {
    let path = settings_path().ok_or("cannot get settings path")?;
    if !path.exists() {
        return Ok(HashMap::new());
    }
    let json = std::fs::read_to_string(&path).map_err(|e| format!("read settings failed: {e}"))?;
    let settings: HashMap<String, serde_json::Value> =
        serde_json::from_str(&json).map_err(|e| format!("parse settings failed: {e}"))?;
    Ok(settings)
}
