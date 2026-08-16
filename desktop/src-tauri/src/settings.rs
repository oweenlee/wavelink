//! 设置持久化 — 保存/加载 JSON 设置文件
//!
//! 路径由 Tauri `app.path().app_data_dir()` 在 setup 阶段注入（`init`），
//! 避免手写路径随 bundle identifier 漂移。命令包装（load_settings /
//! save_settings）接收 AppHandle 供 Tauri 注入；内部模块（webdav / room /
//! subsonic 等）直接调用 `*_impl` 版本，不依赖命令上下文。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tauri::Manager;

/// 设置目录（app_data_dir），由 main.rs setup 注入
static SETTINGS_DIR: OnceLock<PathBuf> = OnceLock::new();

/// 在 app setup 阶段注入设置目录（此后所有读/写都走该目录；幂等）
pub fn init(data_dir: &Path) {
    let _ = SETTINGS_DIR.set(data_dir.to_path_buf());
}

fn settings_path() -> Option<PathBuf> {
    let dir = SETTINGS_DIR.get()?;
    std::fs::create_dir_all(dir).ok()?;
    Some(dir.join("settings.json"))
}

/// 迁移旧版硬编码路径（Linux 曾用 `~/.wavelink/settings.json`，macOS/Windows 与
/// app_data_dir 相同不存在迁移问题）。仅在新文件不存在时迁移，成功后删除旧文件。
fn migrate_legacy(new_path: &Path) {
    if new_path.exists() {
        return;
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let legacy = std::env::var("HOME")
            .ok()
            .map(|home| PathBuf::from(home).join(".wavelink").join("settings.json"));
        if let Some(legacy) = legacy {
            if legacy.exists() {
                if std::fs::rename(&legacy, new_path).is_err() {
                    let _ = std::fs::copy(&legacy, new_path);
                }
                tracing::info!("settings migrated from legacy path: {}", legacy.display());
            }
        }
    }
}

/// 保存设置（内部实现，无命令上下文）
pub fn save_settings_impl(settings: HashMap<String, serde_json::Value>) -> Result<(), String> {
    let path = settings_path().ok_or("cannot get settings path (SETTINGS_DIR not initialized)")?;
    let json = serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?;
    std::fs::write(&path, json).map_err(|e| format!("write settings failed: {e}"))?;
    tracing::info!("settings saved to: {}", path.display());
    Ok(())
}

/// 加载设置（内部实现，无命令上下文）
pub fn load_settings_impl() -> Result<HashMap<String, serde_json::Value>, String> {
    let path = settings_path().ok_or("cannot get settings path (SETTINGS_DIR not initialized)")?;
    if !path.exists() {
        migrate_legacy(&path);
    }
    if !path.exists() {
        return Ok(HashMap::new());
    }
    let json = std::fs::read_to_string(&path).map_err(|e| format!("read settings failed: {e}"))?;
    let settings: HashMap<String, serde_json::Value> =
        serde_json::from_str(&json).map_err(|e| format!("parse settings failed: {e}"))?;
    Ok(settings)
}

/// 保存设置（前端命令入口）
#[tauri::command]
pub fn save_settings(app: tauri::AppHandle, settings: HashMap<String, serde_json::Value>) -> Result<(), String> {
    if let Ok(dir) = app.path().app_data_dir() {
        init(&dir);
    }
    save_settings_impl(settings)
}

/// 加载设置（前端命令入口）
#[tauri::command]
pub fn load_settings(app: tauri::AppHandle) -> Result<HashMap<String, serde_json::Value>, String> {
    if let Ok(dir) = app.path().app_data_dir() {
        init(&dir);
    }
    load_settings_impl()
}