//! 设置持久化 — SQLite key-value 存储（原子 UPSERT）
//!
//! 存储路径由 Tauri `app.path().app_data_dir()` 在 setup 阶段注入（`init`），
//! 避免手写路径随 bundle identifier 漂移。命令包装（load_settings /
//! save_settings）接收 AppHandle 供 Tauri 注入；内部模块（webdav / room /
//! subsonic 等）直接调用 `*_impl` 版本，不依赖命令上下文。
//!
//! 相比旧 JSON 整文件读-改-写：
//! - 写入按 key UPSERT（事务），不会因并发覆盖/崩溃导致整个文件丢失；
//! - save 只更新传入的 key，不再用旧快照覆盖其他模块新写的 key。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tauri::Manager;

use rusqlite::Connection;

/// 设置目录（app_data_dir），由 main.rs setup 注入
static SETTINGS_DIR: OnceLock<PathBuf> = OnceLock::new();

/// 在 app setup 阶段注入设置目录（此后所有读/写都走该目录；幂等）
pub fn init(data_dir: &Path) {
    let _ = SETTINGS_DIR.set(data_dir.to_path_buf());
}

fn settings_db_path() -> Option<PathBuf> {
    let dir = SETTINGS_DIR.get()?;
    std::fs::create_dir_all(dir).ok()?;
    Some(dir.join("settings.db"))
}

/// 打开（必要时创建）设置库，保证表存在
fn open_settings_db() -> Result<Connection, String> {
    let path = settings_db_path().ok_or("cannot get settings path (SETTINGS_DIR not initialized)")?;
    let conn = Connection::open(&path).map_err(|e| format!("open settings db failed: {e}"))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    )
    .map_err(|e| format!("init settings db failed: {e}"))?;
    Ok(conn)
}

/// 保存设置（按 key UPSERT，事务内原子写）
pub fn save_settings_impl(settings: HashMap<String, serde_json::Value>) -> Result<(), String> {
    let mut conn = open_settings_db()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    {
        let mut stmt = tx
            .prepare(
                "INSERT INTO settings(key, value) VALUES(?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .map_err(|e| e.to_string())?;
        for (k, v) in &settings {
            stmt.execute(rusqlite::params![k, v.to_string()])
                .map_err(|e| e.to_string())?;
        }
    }
    tx.commit().map_err(|e| e.to_string())?;
    tracing::debug!("settings saved: {} keys", settings.len());
    Ok(())
}

/// 加载设置（首次为空时尝试从旧版 JSON 迁移）
pub fn load_settings_impl() -> Result<HashMap<String, serde_json::Value>, String> {
    let mut conn = open_settings_db()?;
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM settings", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if count == 0 {
        migrate_from_json(&mut conn)?;
    }
    let mut stmt = conn
        .prepare("SELECT key, value FROM settings")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(|e| e.to_string())?;
    let mut map = HashMap::new();
    for row in rows {
        let (k, v) = row.map_err(|e| e.to_string())?;
        if let Ok(val) = serde_json::from_str(&v) {
            map.insert(k, val);
        } else {
            tracing::warn!("settings key {k} 反序列化失败，跳过");
        }
    }
    Ok(map)
}

/// 旧版 JSON 迁移源：1) app_data_dir/settings.json（macOS/Windows 老版本）；
/// 2) Linux 曾用 ~/.wavelink/settings.json
fn legacy_json_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(dir) = SETTINGS_DIR.get() {
        paths.push(dir.join("settings.json"));
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    if let Ok(home) = std::env::var("HOME") {
        paths.push(PathBuf::from(home).join(".wavelink").join("settings.json"));
    }
    paths
}

/// 迁移旧版 settings.json → SQLite（只迁移一次：成功后重命名为 .migrated，幂等）
fn migrate_from_json(conn: &mut Connection) -> Result<(), String> {
    let Some(src) = legacy_json_paths().into_iter().find(|p| p.exists()) else {
        return Ok(());
    };
    tracing::info!("迁移旧版 JSON 设置: {}", src.display());
    let json = std::fs::read_to_string(&src).map_err(|e| format!("read {} failed: {e}", src.display()))?;
    let settings: HashMap<String, serde_json::Value> =
        serde_json::from_str(&json).map_err(|e| format!("parse {} failed: {e}", src.display()))?;
    if !settings.is_empty() {
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        {
            let mut stmt = tx
                .prepare(
                    "INSERT INTO settings(key, value) VALUES(?1, ?2)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                )
                .map_err(|e| e.to_string())?;
            for (k, v) in &settings {
                stmt.execute(rusqlite::params![k, v.to_string()])
                    .map_err(|e| e.to_string())?;
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    // 成功后改名，避免下次启动重复迁移
    let _ = std::fs::rename(&src, format!("{}.migrated", src.display()));
    Ok(())
}

/// 保存设置（前端命令入口）
#[tauri::command]
pub fn save_settings(
    app: tauri::AppHandle,
    settings: HashMap<String, serde_json::Value>,
) -> Result<(), String> {
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
#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir() -> PathBuf {
        std::env::temp_dir().join(format!("wavelink_settings_test_{}", std::process::id()))
    }

    #[test]
    fn test_sqlite_roundtrip_and_json_migration() {
        let dir = test_dir();
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // 1. 旧版 JSON 一次性迁移
        std::fs::write(dir.join("settings.json"), r#"{"theme":"light","volume":0.5}"#).unwrap();
        init(&dir);
        let loaded = load_settings_impl().unwrap();
        assert_eq!(loaded.get("theme").and_then(|v| v.as_str()), Some("light"));
        assert_eq!(loaded.get("volume").and_then(|v| v.as_f64()), Some(0.5));
        assert!(!dir.join("settings.json").exists());
        assert!(dir.join("settings.json.migrated").exists());

        // 2. UPSERT 只写传入 key，不覆盖其他 key
        let mut s = HashMap::new();
        s.insert("theme".into(), serde_json::json!("dark"));
        s.insert("accentColor".into(), serde_json::json!("#123456"));
        save_settings_impl(s).unwrap();
        let loaded = load_settings_impl().unwrap();
        assert_eq!(loaded.get("theme").and_then(|v| v.as_str()), Some("dark"));
        assert_eq!(loaded.get("accentColor").and_then(|v| v.as_str()), Some("#123456"));
        assert_eq!(loaded.get("volume").and_then(|v| v.as_f64()), Some(0.5));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
