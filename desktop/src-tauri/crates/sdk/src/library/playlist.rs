use std::fs;
use std::path::{Path, PathBuf};

/// 带元数据的歌单条目，用于导出包含标题和时长的歌单
#[derive(Debug, Clone)]
pub struct PlaylistEntry {
    pub path: String,
    pub title: Option<String>,
    pub duration_secs: Option<f64>,
}

/// 导入歌单，返回曲目路径列表
pub fn import_playlist(path: &Path) -> Result<Vec<String>, String> {
    let ext = ext(path);
    match ext.as_str() {
        "m3u" | "m3u8" => import_m3u(path),
        "pls" => import_pls(path),
        _ => Err(format!("不支持格式: .{ext}")),
    }
}

/// 导出歌单（基础版，不含曲目标题/时长信息）
pub fn export_playlist(path: &Path, entries: &[String]) -> Result<(), String> {
    let ext = ext(path);
    let plain: Vec<PlaylistEntry> = entries.iter().map(|p| PlaylistEntry {
        path: p.clone(), title: None, duration_secs: None,
    }).collect();
    match ext.as_str() {
        "m3u" | "m3u8" => export_m3u(path, &plain),
        "pls" => export_pls(path, &plain),
        _ => Err(format!("不支持格式: .{ext}")),
    }
}

/// 导出歌单（含元数据版本，写入 EXTINF/Title）
pub fn export_playlist_with_meta(path: &Path, entries: &[PlaylistEntry]) -> Result<(), String> {
    let ext = ext(path);
    match ext.as_str() {
        "m3u" | "m3u8" => export_m3u(path, entries),
        "pls" => export_pls(path, entries),
        _ => Err(format!("不支持格式: .{ext}")),
    }
}

fn ext(path: &Path) -> String {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase())
        .unwrap_or_default()
}

fn parent(path: &Path) -> PathBuf {
    path.parent().unwrap_or(Path::new(".")).to_path_buf()
}

/// 解析路径（支持相对路径和绝对路径）
fn resolve_path(line: &str, base_dir: &Path) -> String {
    let p = Path::new(line);
    if p.is_absolute() {
        line.to_string()
    } else {
        base_dir.join(line).to_string_lossy().into_owned()
    }
}

/// 解析 M3U 文件（支持扩展格式 #EXTM3U）
fn import_m3u(path: &Path) -> Result<Vec<String>, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("读取 M3U 失败: {e}"))?;
    let base = parent(path);
    let mut entries = Vec::new();

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        entries.push(resolve_path(line, &base));
    }

    Ok(entries)
}

/// 解析 PLS 文件
fn import_pls(path: &Path) -> Result<Vec<String>, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("读取 PLS 失败: {e}"))?;
    let base = parent(path);

    // 收集所有 FileN=xxx 的行，按序号排序
    let mut file_entries: Vec<(u32, String)> = Vec::new();
    for line in content.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("File") {
            if let Some(eq_pos) = rest.find('=') {
                let num_str = &rest[..eq_pos];
                let path_val = rest[eq_pos + 1..].trim();
                if let Ok(num) = num_str.parse::<u32>() {
                    file_entries.push((num, resolve_path(path_val, &base)));
                }
            }
        }
    }

    file_entries.sort_by_key(|(num, _)| *num);
    Ok(file_entries.into_iter().map(|(_, p)| p).collect())
}

/// 导出 M3U 文件（扩展格式，含 #EXTINF）
fn export_m3u(path: &Path, entries: &[PlaylistEntry]) -> Result<(), String> {
    let mut content = String::from("#EXTM3U\n");
    for entry in entries {
        let dur = entry.duration_secs.map(|d| d.round() as i64).unwrap_or(-1);
        let title = entry.title.as_deref().unwrap_or("");
        content.push_str(&format!("#EXTINF:{},{}\n", dur, title));
        content.push_str(&entry.path);
        content.push('\n');
    }
    fs::write(path, content).map_err(|e| format!("写入 M3U 失败: {e}"))
}

/// 导出 PLS 文件（含 Title 信息）
fn export_pls(path: &Path, entries: &[PlaylistEntry]) -> Result<(), String> {
    let mut content = String::from("[playlist]\n");
    for (i, entry) in entries.iter().enumerate() {
        let num = i + 1;
        let title = entry.title.as_deref().unwrap_or("");
        let dur = entry.duration_secs.map(|d| d.round() as i64).unwrap_or(-1);
        content.push_str(&format!("File{num}={}\n", entry.path));
        content.push_str(&format!("Title{num}={title}\n"));
        content.push_str(&format!("Length{num}={dur}\n"));
    }
    content.push_str(&format!("NumberOfEntries={}\n", entries.len()));
    content.push_str("Version=2\n");
    fs::write(path, content).map_err(|e| format!("写入 PLS 失败: {e}"))
}
