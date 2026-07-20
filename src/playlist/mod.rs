//! 播放列表解析：M3U / M3U8 / PLS。

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

/// 播放列表条目
#[derive(Debug, Clone)]
pub struct PlaylistEntry {
    /// 音频文件路径（已解析为绝对路径或原样保留）
    pub path: String,
    /// 曲名（EXTINF / PLS 标题），可能为空
    pub title: Option<String>,
    /// 时长（秒，EXTINF / PLS Length），可能为 0
    pub duration_secs: f64,
}

/// 解析播放列表文件，自动识别 M3U / M3U8 / PLS 格式
pub fn parse_playlist(path: &Path) -> Result<Vec<PlaylistEntry>, String> {
    let file = File::open(path).map_err(|e| format!("无法打开播放列表: {e}"))?;
    let reader = BufReader::new(file);
    let lines: Vec<String> = reader.lines()
        .filter_map(|l| l.ok())
        .collect();

    if lines.is_empty() {
        return Err("播放列表为空".into());
    }

    // 检查首行格式
    let first = lines[0].trim();
    if first == "[playlist]" {
        parse_pls(&lines, path)
    } else {
        parse_m3u(&lines, path)
    }
}

/// 解析 M3U / M3U8 格式
fn parse_m3u(lines: &[String], list_path: &Path) -> Result<Vec<PlaylistEntry>, String> {
    let mut entries = Vec::new();
    let mut extinf_title: Option<String> = None;
    let mut extinf_dur: f64 = 0.0;
    let list_dir = list_path.parent().unwrap_or(Path::new("."));

    for line in lines {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            // #EXTINF:123,Title
            if let Some(rest) = trimmed.strip_prefix("#EXTINF:") {
                if let Some(comma) = rest.find(',') {
                    extinf_dur = rest[..comma].trim().parse::<f64>().unwrap_or(0.0);
                    let title = rest[comma + 1..].trim();
                    extinf_title = if title.is_empty() { None } else { Some(title.to_string()) };
                }
            }
            // 其他 # 注释 / #EXTM3U 忽略
            continue;
        }

        // 解析文件路径
        let resolved = resolve_path(trimmed, list_dir);
        entries.push(PlaylistEntry {
            path: resolved,
            title: extinf_title.take(),
            duration_secs: extinf_dur,
        });
        extinf_dur = 0.0;
    }

    if entries.is_empty() {
        Err("M3U 中未找到有效条目".into())
    } else {
        Ok(entries)
    }
}

/// 解析 PLS 格式
fn parse_pls(lines: &[String], list_path: &Path) -> Result<Vec<PlaylistEntry>, String> {
    let mut entries = Vec::new();
    let list_dir = list_path.parent().unwrap_or(Path::new("."));
    let mut file_map: std::collections::HashMap<usize, String> = std::collections::HashMap::new();
    let mut title_map: std::collections::HashMap<usize, String> = std::collections::HashMap::new();
    let mut length_map: std::collections::HashMap<usize, f64> = std::collections::HashMap::new();

    for line in lines {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('[') || trimmed.starts_with("NumberOfEntries") || trimmed.starts_with("Version") {
            continue;
        }
        // File1=path, Title1=name, Length1=123
        if let Some(eq) = trimmed.find('=') {
            let key = trimmed[..eq].trim();
            let value = trimmed[eq + 1..].trim();
            // 提取数字索引
            let num: usize = key.chars().skip_while(|c| !c.is_ascii_digit()).collect::<String>().parse().unwrap_or(0);
            if key.to_ascii_lowercase().starts_with("file") {
                file_map.insert(num, resolve_path(value, list_dir));
            } else if key.to_ascii_lowercase().starts_with("title") {
                title_map.insert(num, value.to_string());
            } else if key.to_ascii_lowercase().starts_with("length") {
                length_map.insert(num, value.parse::<f64>().unwrap_or(0.0));
            }
        }
    }

    let mut keys: Vec<usize> = file_map.keys().copied().collect();
    keys.sort();
    for k in keys {
        if let Some(path) = file_map.remove(&k) {
            entries.push(PlaylistEntry {
                path,
                title: title_map.remove(&k),
                duration_secs: length_map.remove(&k).unwrap_or(0.0),
            });
        }
    }

    if entries.is_empty() {
        Err("PLS 中未找到有效条目".into())
    } else {
        Ok(entries)
    }
}

/// 解析文件路径：相对路径相对于列表文件所在目录，绝对路径/URL 原样保留
fn resolve_path(path_str: &str, list_dir: &Path) -> String {
    let p = Path::new(path_str);
    if p.is_absolute() || path_str.starts_with("http://") || path_str.starts_with("https://") {
        path_str.to_string()
    } else {
        // 相对于列表文件目录
        list_dir.join(p).to_string_lossy().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicU32, Ordering};

    static TMP_COUNTER: AtomicU32 = AtomicU32::new(0);

    fn write_tmp(content: &str) -> String {
        let id = TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("playlist_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join(format!("test_{id}.m3u"));
        let mut f = std::fs::File::create(&path).unwrap();
        write!(f, "{}", content).unwrap();
        path.to_string_lossy().to_string()
    }

    #[test]
    fn test_m3u_basic() {
        let path = write_tmp("song1.mp3\nsong2.flac\n");
        let entries = parse_playlist(Path::new(&path)).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries[0].path.ends_with("song1.mp3"));
        assert!(entries[1].path.ends_with("song2.flac"));
    }

    #[test]
    fn test_m3u_extinf() {
        let path = write_tmp("#EXTM3U\n#EXTINF:180,Test Artist - Test Title\nsong.mp3\n");
        let entries = parse_playlist(Path::new(&path)).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title.as_deref(), Some("Test Artist - Test Title"));
        assert!((entries[0].duration_secs - 180.0).abs() < 0.01);
    }

    #[test]
    fn test_pls_basic() {
        let path = write_tmp("[playlist]\nFile1=a.mp3\nTitle1=Song A\nLength1=200\nFile2=b.flac\nNumberOfEntries=2\nVersion=2\n");
        let entries = parse_playlist(Path::new(&path)).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].title.as_deref(), Some("Song A"));
        assert!((entries[0].duration_secs - 200.0).abs() < 0.01);
        assert_eq!(entries[1].title, None);
    }

    #[test]
    fn test_m3u_empty() {
        let path = write_tmp("# just a comment\n");
        assert!(parse_playlist(Path::new(&path)).is_err());
    }

    #[test]
    fn test_pls_missing_file() {
        let path = write_tmp("[playlist]\nNumberOfEntries=1\nVersion=2\n");
        assert!(parse_playlist(Path::new(&path)).is_err());
    }
}
