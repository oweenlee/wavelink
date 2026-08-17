use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

/// SMB URL userinfo 编码集：只保留 RFC3986 unreserved 字符（其余全部百分号编码）。
/// 凭据中的 @ : / % 等特殊字符必须编码，否则 mount_smbfs 解析 URL 失败。
const USERINFO_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-').remove(b'.').remove(b'_').remove(b'~');

/// 名称清洗：路径分隔符换下划线，防止挂载点路径穿越
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn sanitize_name(name: &str) -> String {
    name.chars()
        .map(|c| if c == '/' || c == '\\' { '_' } else { c })
        .collect()
}

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
    pub fn new(db_path: &Path) -> Self {
        let mgr = Self {
            db_path: db_path.to_path_buf(),
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
            .map_err(|e| format!("keyring set password failed: {e}"))?;
        // 写后读回校验：确保密码真正写入系统钥匙串，
        // 防止出现"数据库有记录但钥匙串没有条目"导致挂载时取不到密码。
        let stored = entry
            .get_password()
            .map_err(|e| format!("keyring verify failed: {e}"))?;
        if stored != password {
            return Err("keyring verify mismatch: password was not saved".to_string());
        }
        Ok(())
    }

    pub fn get_password(&self, id: &str) -> Result<String, String> {
        let entry =
            keyring::Entry::new("wavelink-nas", id).map_err(|_| "cannot access system keychain".to_string())?;
        entry.get_password().map_err(|e| {
            let msg = match &e {
                keyring::Error::NoEntry => format!(
                    "password not found in system keychain, please re-enter it (nas id: {id})"
                ),
                _ => format!("get password failed: {e}"),
            };
            msg
        })
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
        // macOS/Linux：挂载点目录在卸载后仍存在（新挂载点是我们自建的用户目录），
        // 不能用"目录存在"判断；解析 `mount` 输出里是否有挂到该路径的条目才可靠。
        #[cfg(not(target_os = "windows"))]
        {
            let needle = format!(" on {} ", path);
            std::process::Command::new("mount")
                .output()
                .map(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .lines()
                        .any(|l| l.contains(&needle))
                })
                .unwrap_or(false)
        }
        #[cfg(target_os = "windows")]
        {
            std::path::Path::new(&path).exists()
        }
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
        // macOS：挂载点必须在用户可写目录——/Volumes 为 root 所有无法 mkdir，
        // 而 mount_smbfs 要求挂载点预先存在，往 /Volumes 挂必然失败。
        #[cfg(target_os = "macos")]
        {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
            format!("{}/.wavelink/mounts/{}", home, sanitize_name(name))
        }
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

    /// 构造 smb:// URL：用户名/密码/服务器/共享名全部百分号编码，
    /// 避免凭据或共享名含特殊字符（@ : 空格 撇号等）导致 URL 解析失败。
    fn smb_url(conn: &NasConnection, password: &str) -> String {
        let user = utf8_percent_encode(&conn.username, USERINFO_SET);
        let pass = utf8_percent_encode(password, USERINFO_SET);
        let server = utf8_percent_encode(&conn.server, USERINFO_SET);
        let share = utf8_percent_encode(&conn.share, USERINFO_SET);
        format!("smb://{}:{}@{}/{}", user, pass, server, share)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn conn(user: &str, server: &str, share: &str) -> NasConnection {
        NasConnection {
            id: "t".into(),
            name: "n".into(),
            server: server.into(),
            share: share.into(),
            username: user.into(),
            auto_mount: false,
            mount_path: String::new(),
        }
    }

    /// 凭据含特殊字符时必须百分号编码，否则 mount_smbfs URL 解析失败
    #[test]
    fn smb_url_encodes_special_chars() {
        let c = conn("qin", "192.168.1.10", "misic");
        // 密码含 @ : / 空格
        let url = NasManager::smb_url(&c, "p@ss:w/ord 1");
        assert_eq!(url, "smb://qin:p%40ss%3Aw%2Ford%201@192.168.1.10/misic");
    }

    /// 共享名含空格/撇号（如 macOS 默认 "xxx's Public Folder"）也要编码
    #[test]
    fn smb_url_encodes_share_name() {
        let c = conn("qin", "127.0.0.1", "smbtest's Public Folder");
        let url = NasManager::smb_url(&c, "pw");
        assert_eq!(url, "smb://qin:pw@127.0.0.1/smbtest%27s%20Public%20Folder");
    }

    /// 普通凭据不应被过度编码
    #[test]
    fn smb_url_plain_credentials_unchanged() {
        let c = conn("alice", "nas.local", "Music");
        let url = NasManager::smb_url(&c, "Secret123");
        assert_eq!(url, "smb://alice:Secret123@nas.local/Music");
    }

    /// unreserved 字符 - _ . ~ 保持原样
    #[test]
    fn smb_url_keeps_unreserved() {
        let c = conn("u", "s", "sh");
        let url = NasManager::smb_url(&c, "a-b_c.d~e");
        assert_eq!(url, "smb://u:a-b_c.d~e@s/sh");
    }

    /// 挂载点名称中的路径分隔符被清洗，防止路径穿越
    #[test]
    fn sanitize_name_strips_separators() {
        assert_eq!(sanitize_name("a/b\\c"), "a_b_c");
        assert_eq!(sanitize_name("../etc"), ".._etc");
        assert_eq!(sanitize_name("misic"), "misic");
    }
}
