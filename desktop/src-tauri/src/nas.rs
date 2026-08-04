use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NasConnection {
    pub id: String,
    pub name: String,
    pub server: String,
    pub share: String,
    pub username: String,
    pub auto_mount: bool,
    pub mount_path: String,
}

pub struct NasManager {
    db_path: PathBuf,
}

impl NasManager {
    pub fn new(db_path: &PathBuf) -> Self {
        let mgr = Self {
            db_path: db_path.clone(),
        };
        if let Err(e) = mgr.migrate() {
            tracing::warn!("NAS table migration failed: {e}");
        }
        mgr
    }

    /// 更新挂载路径到数据库（三平台共享）
    fn update_mount_path(&self, mount_path: &str, conn_id: &str) {
        if let Ok(db) = self.connect() {
            db.execute(
                "UPDATE nas_connections SET mount_path = ?1 WHERE id = ?2",
                rusqlite::params![mount_path, conn_id],
            )
            .ok();
        }
    }

    fn connect(&self) -> Result<rusqlite::Connection, String> {
        rusqlite::Connection::open(&self.db_path)
            .map_err(|e| format!("open db failed: {e}"))
    }

    fn migrate(&self) -> Result<(), String> {
        let conn = self.connect()?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS nas_connections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                server TEXT NOT NULL,
                share TEXT NOT NULL,
                username TEXT NOT NULL DEFAULT '',
                auto_mount INTEGER NOT NULL DEFAULT 0,
                mount_path TEXT NOT NULL DEFAULT ''
            );",
        )
        .map_err(|e| format!("create table failed: {e}"))?;
        Ok(())
    }

    pub fn list(&self) -> Result<Vec<NasConnection>, String> {
        let conn = self.connect()?;
        let mut stmt = conn
            .prepare("SELECT id, name, server, share, username, auto_mount, mount_path FROM nas_connections ORDER BY name")
            .map_err(|e| format!("query prepare failed: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(NasConnection {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    server: row.get(2)?,
                    share: row.get(3)?,
                    username: row.get(4)?,
                    auto_mount: row.get::<_, i32>(5)? != 0,
                    mount_path: row.get(6)?,
                })
            })
            .map_err(|e| format!("query failed: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("read row failed: {e}"))?);
        }
        Ok(result)
    }

    pub fn add(&self, conn: &NasConnection) -> Result<(), String> {
        let db = self.connect()?;
        db.execute(
            "INSERT INTO nas_connections (id, name, server, share, username, auto_mount, mount_path) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![conn.id, conn.name, conn.server, conn.share, conn.username, conn.auto_mount as i32, conn.mount_path],
        )
        .map_err(|e| format!("insert failed: {e}"))?;
        Ok(())
    }

    pub fn remove(&self, id: &str) -> Result<(), String> {
        let db = self.connect()?;
        db.execute(
            "DELETE FROM nas_connections WHERE id = ?1",
            rusqlite::params![id],
        )
        .map_err(|e| format!("delete failed: {e}"))?;
        self.delete_password(id);
        Ok(())
    }

    pub fn set_password(&self, id: &str, password: &str) -> Result<(), String> {
        let entry = keyring::Entry::new("wavelink-nas", id)
            .map_err(|e| format!("keyring entry create failed: {e}"))?;
        entry
            .set_password(password)
            .map_err(|e| format!("keyring set password failed: {e}"))
    }

    pub fn get_password(&self, id: &str) -> Result<String, String> {
        let entry =
            keyring::Entry::new("wavelink-nas", id).map_err(|_| "cannot access system keychain".to_string())?;
        entry.get_password().map_err(|e| format!("get password failed: {e}"))
    }

    fn delete_password(&self, id: &str) {
        if let Ok(entry) = keyring::Entry::new("wavelink-nas", id) {
            entry.delete_credential().ok();
        }
    }

    pub fn mount(&self, id: &str) -> Result<String, String> {
        let conn = self
            .list()?
            .into_iter()
            .find(|c| c.id == id)
            .ok_or_else(|| "NAS connection not found".to_string())?;
        let password = self.get_password(id)?;
        self.platform_mount(&conn, &password)
    }

    pub fn unmount(&self, id: &str) -> Result<(), String> {
        let conn = self
            .list()?
            .into_iter()
            .find(|c| c.id == id)
            .ok_or_else(|| "NAS connection not found".to_string())?;
        self.platform_unmount(&conn)
    }

    pub fn is_mounted(&self, id: &str) -> bool {
        let Some(conn) = self.list().ok().and_then(|v| v.into_iter().find(|c| c.id == id)) else {
            return false;
        };
        let path = if conn.mount_path.is_empty() {
            self.default_mount_path(&conn.name)
        } else {
            conn.mount_path.clone()
        };
        std::path::Path::new(&path).exists()
    }

    pub fn auto_mount_all(&self) {
        let connections = match self.list() {
            Ok(c) => c.into_iter().filter(|c| c.auto_mount).collect::<Vec<_>>(),
            Err(_) => return,
        };
        for conn in connections {
            if self.is_mounted(&conn.id) {
                continue;
            }
            let password = match self.get_password(&conn.id) {
                Ok(p) => p,
                Err(e) => {
                    tracing::warn!("auto-mount '{}' failed: cannot read password: {e}", conn.name);
                    continue;
                }
            };
            match self.platform_mount(&conn, &password) {
                Ok(path) => tracing::info!("auto-mounted NAS '{}' at {}", conn.name, path),
                Err(e) => tracing::warn!("auto-mount NAS '{}' failed: {e}", conn.name),
            }
        }
    }

    fn default_mount_path(&self, name: &str) -> String {
        #[cfg(target_os = "macos")]
        { format!("/Volumes/{}", name) }
        #[cfg(target_os = "linux")]
        { format!("/mnt/{}", name) }
        #[cfg(target_os = "windows")]
        { format!("Z:") }
    }

    fn mount_path_for(&self, conn: &NasConnection) -> String {
        if conn.mount_path.is_empty() {
            self.default_mount_path(&conn.name)
        } else {
            conn.mount_path.clone()
        }
    }

    fn smb_url(conn: &NasConnection, password: &str) -> String {
        format!("smb://{}:{}@{}/{}", conn.username, password, conn.server, conn.share)
    }

    /// 执行挂载命令并更新挂载路径
    fn exec_mount(&self, conn: &NasConnection, cmd: &mut Command) -> Result<String, String> {
        let mount_path = self.mount_path_for(conn);
        std::fs::create_dir_all(&mount_path).map_err(|e| format!("mkdir mount point failed: {e}"))?;

        let output = cmd.output().map_err(|e| format!("mount cmd failed: {e}"))?;
        if output.status.success() {
            self.update_mount_path(&mount_path, &conn.id);
            Ok(mount_path)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("mount failed: {}", stderr.trim()))
        }
    }

    /// Execute unmount command
    fn exec_unmount(&self, _conn: &NasConnection, cmd: &mut Command) -> Result<(), String> {
        let output = cmd.output().map_err(|e| format!("unmount cmd failed: {e}"))?;
        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("unmount failed: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "macos")]
    fn platform_mount(&self, conn: &NasConnection, password: &str) -> Result<String, String> {
        let url = Self::smb_url(conn, password);
        let mount_path = self.mount_path_for(conn);
        self.exec_mount(conn, Command::new("mount_smbfs").args([&url, &mount_path]))
    }

    #[cfg(target_os = "macos")]
    fn platform_unmount(&self, conn: &NasConnection) -> Result<(), String> {
        let path = self.mount_path_for(conn);
        self.exec_unmount(conn, Command::new("umount").args([&path]))
    }

    #[cfg(target_os = "linux")]
    fn platform_mount(&self, conn: &NasConnection, password: &str) -> Result<String, String> {
        let share = format!("//{}/{}", conn.server, conn.share);
        let opts = format!("username={},password={}", conn.username, password);
        // Linux mount needs mount_path as last arg
        let mount_path = self.mount_path_for(conn);
        std::fs::create_dir_all(&mount_path).map_err(|e| format!("mkdir mount point failed: {e}"))?;
        let output = Command::new("mount")
            .args(["-t", "cifs", &share, &mount_path, "-o", &opts])
            .output()
            .map_err(|e| format!("mount cmd failed: {e}"))?;
        if output.status.success() {
            self.update_mount_path(&mount_path, &conn.id);
            Ok(mount_path)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("mount failed: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "linux")]
    fn platform_unmount(&self, conn: &NasConnection) -> Result<(), String> {
        let path = self.mount_path_for(conn);
        self.exec_unmount(conn, Command::new("umount").args([&path]))
    }

    #[cfg(target_os = "windows")]
    fn platform_mount(&self, conn: &NasConnection, password: &str) -> Result<String, String> {
        let share = format!("\\\\{}\\{}", conn.server, conn.share);
        let output = Command::new("net")
            .args(["use", &share, password, &format!("/user:{}", conn.username)])
            .output()
            .map_err(|e| format!("net use cmd failed: {e}"))?;
        if output.status.success() {
            self.update_mount_path(&share, &conn.id);
            Ok(share)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("mount failed: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "windows")]
    fn platform_unmount(&self, conn: &NasConnection) -> Result<(), String> {
        let share = self.mount_path_for(conn);
        let output = Command::new("net")
            .args(["use", &share, "/delete"])
            .output()
            .map_err(|e| format!("net use cmd failed: {e}"))?;
        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("unmount failed: {}", stderr.trim()))
        }
    }
}
