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
            tracing::warn!("NAS 表迁移失败: {e}");
        }
        mgr
    }

    fn connect(&self) -> Result<rusqlite::Connection, String> {
        rusqlite::Connection::open(&self.db_path)
            .map_err(|e| format!("打开数据库失败: {e}"))
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
        .map_err(|e| format!("创建 NAS 表失败: {e}"))?;
        Ok(())
    }

    pub fn list(&self) -> Result<Vec<NasConnection>, String> {
        let conn = self.connect()?;
        let mut stmt = conn
            .prepare("SELECT id, name, server, share, username, auto_mount, mount_path FROM nas_connections ORDER BY name")
            .map_err(|e| format!("查询准备失败: {e}"))?;
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
            .map_err(|e| format!("查询失败: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            result.push(row.map_err(|e| format!("读取行失败: {e}"))?);
        }
        Ok(result)
    }

    pub fn add(&self, conn: &NasConnection) -> Result<(), String> {
        let db = self.connect()?;
        db.execute(
            "INSERT INTO nas_connections (id, name, server, share, username, auto_mount, mount_path) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![conn.id, conn.name, conn.server, conn.share, conn.username, conn.auto_mount as i32, conn.mount_path],
        )
        .map_err(|e| format!("插入 NAS 连接失败: {e}"))?;
        Ok(())
    }

    pub fn remove(&self, id: &str) -> Result<(), String> {
        let db = self.connect()?;
        db.execute(
            "DELETE FROM nas_connections WHERE id = ?1",
            rusqlite::params![id],
        )
        .map_err(|e| format!("删除 NAS 连接失败: {e}"))?;
        self.delete_password(id);
        Ok(())
    }

    pub fn set_password(&self, id: &str, password: &str) -> Result<(), String> {
        let entry = keyring::Entry::new("wavelink-nas", id)
            .map_err(|e| format!("创建钥匙串条目失败: {e}"))?;
        entry
            .set_password(password)
            .map_err(|e| format!("保存密码到钥匙串失败: {e}"))
    }

    pub fn get_password(&self, id: &str) -> Result<String, String> {
        let entry =
            keyring::Entry::new("wavelink-nas", id).map_err(|_| "无法访问系统钥匙串".to_string())?;
        entry.get_password().map_err(|e| format!("读取密码失败: {e}"))
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
            .ok_or_else(|| "未找到 NAS 连接".to_string())?;
        let password = self.get_password(id)?;
        self.platform_mount(&conn, &password)
    }

    pub fn unmount(&self, id: &str) -> Result<(), String> {
        let conn = self
            .list()?
            .into_iter()
            .find(|c| c.id == id)
            .ok_or_else(|| "未找到 NAS 连接".to_string())?;
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
                    tracing::warn!("自动挂载 '{}' 失败: 无法读取密码: {e}", conn.name);
                    continue;
                }
            };
            match self.platform_mount(&conn, &password) {
                Ok(path) => tracing::info!("自动挂载 NAS '{}' 到 {}", conn.name, path),
                Err(e) => tracing::warn!("自动挂载 NAS '{}' 失败: {e}", conn.name),
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

    #[cfg(target_os = "macos")]
    fn platform_mount(&self, conn: &NasConnection, password: &str) -> Result<String, String> {
        let mount_path = if conn.mount_path.is_empty() {
            format!("/Volumes/{}", conn.name)
        } else {
            conn.mount_path.clone()
        };
        std::fs::create_dir_all(&mount_path).map_err(|e| format!("创建挂载点失败: {e}"))?;

        // SMB URL
        let url = if conn.username.is_empty() {
            format!("smb://{}:{}@{}/{}", conn.username, password, conn.server, conn.share)
        } else {
            format!("smb://{}:{}@{}/{}", conn.username, password, conn.server, conn.share)
        };

        let output = Command::new("mount_smbfs")
            .args([&url, &mount_path])
            .output()
            .map_err(|e| format!("执行 mount_smbfs 失败: {e}"))?;
        if output.status.success() {
            let db = self.connect().ok();
            if let Some(db) = db {
                db.execute(
                    "UPDATE nas_connections SET mount_path = ?1 WHERE id = ?2",
                    rusqlite::params![mount_path, conn.id],
                )
                .ok();
            }
            Ok(mount_path)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("挂载失败: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "macos")]
    fn platform_unmount(&self, conn: &NasConnection) -> Result<(), String> {
        let path = if conn.mount_path.is_empty() {
            format!("/Volumes/{}", conn.name)
        } else {
            conn.mount_path.clone()
        };
        let output = Command::new("umount")
            .args([&path])
            .output()
            .map_err(|e| format!("执行 umount 失败: {e}"))?;
        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("卸载失败: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "linux")]
    fn platform_mount(&self, conn: &NasConnection, password: &str) -> Result<String, String> {
        let mount_path = if conn.mount_path.is_empty() {
            format!("/mnt/{}", conn.name)
        } else {
            conn.mount_path.clone()
        };
        std::fs::create_dir_all(&mount_path).map_err(|e| format!("创建挂载点失败: {e}"))?;

        let share = format!("//{}/{}", conn.server, conn.share);
        let opts = format!("username={},password={}", conn.username, password);
        let output = Command::new("mount")
            .args(["-t", "cifs", &share, &mount_path, "-o", &opts])
            .output()
            .map_err(|e| format!("执行 mount 失败: {e}"))?;
        if output.status.success() {
            let db = self.connect().ok();
            if let Some(db) = db {
                db.execute(
                    "UPDATE nas_connections SET mount_path = ?1 WHERE id = ?2",
                    rusqlite::params![mount_path, conn.id],
                )
                .ok();
            }
            Ok(mount_path)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("挂载失败: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "linux")]
    fn platform_unmount(&self, conn: &NasConnection) -> Result<(), String> {
        let path = if conn.mount_path.is_empty() {
            format!("/mnt/{}", conn.name)
        } else {
            conn.mount_path.clone()
        };
        let output = Command::new("umount")
            .args([&path])
            .output()
            .map_err(|e| format!("执行 umount 失败: {e}"))?;
        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("卸载失败: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "windows")]
    fn platform_mount(&self, conn: &NasConnection, password: &str) -> Result<String, String> {
        let share = format!("\\\\{}\\{}", conn.server, conn.share);
        let output = Command::new("net")
            .args(["use", &share, password, &format!("/user:{}", conn.username)])
            .output()
            .map_err(|e| format!("执行 net use 失败: {e}"))?;
        if output.status.success() {
            let mount_path = share.clone();
            let db = self.connect().ok();
            if let Some(db) = db {
                db.execute(
                    "UPDATE nas_connections SET mount_path = ?1 WHERE id = ?2",
                    rusqlite::params![mount_path, conn.id],
                )
                .ok();
            }
            Ok(mount_path)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("挂载失败: {}", stderr.trim()))
        }
    }

    #[cfg(target_os = "windows")]
    fn platform_unmount(&self, conn: &NasConnection) -> Result<(), String> {
        let share = if conn.mount_path.is_empty() {
            format!("\\\\{}\\{}", conn.server, conn.share)
        } else {
            conn.mount_path.clone()
        };
        let output = Command::new("net")
            .args(["use", &share, "/delete"])
            .output()
            .map_err(|e| format!("执行 net use /delete 失败: {e}"))?;
        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("卸载失败: {}", stderr.trim()))
        }
    }
}
