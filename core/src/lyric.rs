//! LRC 歌词解析与同步
//!
//! 支持标准 LRC 格式：
//! - 时间标签 `[mm:ss.xx]`（百分秒/毫秒皆可，可一行多标签）
//! - ID 标签 `[ti:标题]` `[ar:歌手]` `[al:专辑]` `[by:制作人]`
//! - 偏移标签 `[offset:±ms]`（整体时间平移，正值提前）
//!
//! 典型用法（UI 侧按播放进度查询）：
//! ```no_run
//! use audio_core::lyric;
//! if let Some(path) = lyric::find_lrc_file(std::path::Path::new("/music/song.flac")) {
//!     let lyrics = lyric::load_lrc(&path).unwrap();
//!     let position = 42.5; // 当前播放秒数
//!     if let Some(idx) = lyrics.line_at(position) {
//!         println!("当前歌词: {}", lyrics.lines[idx].text);
//!     }
//! }
//! ```

use std::path::{Path, PathBuf};

/// 单行歌词
#[derive(Debug, Clone, PartialEq)]
pub struct LyricLine {
    /// 出现时间（秒，已含 offset 修正）
    pub time_secs: f64,
    /// 歌词文本（已去除首尾空白）
    pub text: String,
}

/// 解析后的歌词
#[derive(Debug, Clone, Default)]
pub struct Lyrics {
    /// 按时间升序排列的歌词行
    pub lines: Vec<LyricLine>,
    /// 标题（[ti:]）
    pub title: Option<String>,
    /// 歌手（[ar:]）
    pub artist: Option<String>,
    /// 专辑（[al:]）
    pub album: Option<String>,
}

impl Lyrics {
    /// 是否为空歌词（无有效行）
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    /// 二分查找给定时刻（秒）应显示的歌词行索引。
    /// 返回最后一个 time_secs <= secs 的行；若尚未到第一行则 None。
    pub fn line_at(&self, secs: f64) -> Option<usize> {
        match self.lines.binary_search_by(|l| l.time_secs.partial_cmp(&secs).unwrap_or(std::cmp::Ordering::Equal)) {
            Ok(i) => Some(i),
            Err(i) => i.checked_sub(1),
        }
    }
}

/// 解析 LRC 文本内容
pub fn parse_lrc(content: &str) -> Lyrics {
    let mut lines: Vec<LyricLine> = Vec::new();
    let mut title = None;
    let mut artist = None;
    let mut album = None;
    let mut offset_ms: f64 = 0.0;

    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }

        // 收集本行所有 [xxx] 标签，剩余为文本
        let mut rest = line;
        let mut stamps: Vec<f64> = Vec::new();
        let mut id_tags: Vec<(String, String)> = Vec::new();

        while let Some(start) = rest.find('[') {
            let Some(end_rel) = rest[start..].find(']') else { break };
            let end = start + end_rel;
            let tag = &rest[start + 1..end];
            rest = &rest[end + 1..];

            if let Some(secs) = parse_timestamp(tag) {
                stamps.push(secs);
            } else if let Some((key, val)) = tag.split_once(':') {
                id_tags.push((key.trim().to_ascii_lowercase(), val.trim().to_string()));
            }
        }

        for (key, val) in id_tags {
            if stamps.is_empty() {
                match key.as_str() {
                    "ti" => title = Some(val),
                    "ar" => artist = Some(val),
                    "al" => album = Some(val),
                    "offset" => {
                        if let Ok(ms) = val.parse::<f64>() {
                            offset_ms = ms;
                        }
                    }
                    _ => {}
                }
            }
        }

        if stamps.is_empty() {
            continue;
        }

        let text = rest.trim().to_string();
        // 一行多标签：每个时间戳生成一行（共享文本）
        for t in stamps {
            lines.push(LyricLine { time_secs: t, text: text.clone() });
        }
    }

    // 应用 offset（正值 = 提前）并排序
    let offset_secs = offset_ms / 1000.0;
    for l in lines.iter_mut() {
        l.time_secs = (l.time_secs - offset_secs).max(0.0);
    }
    lines.sort_by(|a, b| a.time_secs.partial_cmp(&b.time_secs).unwrap_or(std::cmp::Ordering::Equal));

    Lyrics { lines, title, artist, album }
}

/// 解析时间标签内容（不含方括号），如 "01:23.45" → 83.45 秒。
/// 支持 [mm:ss]、[mm:ss.xx]、[mm:ss.xxx]。
fn parse_timestamp(tag: &str) -> Option<f64> {
    let (min_str, sec_str) = tag.split_once(':')?;
    let minutes: f64 = min_str.trim().parse().ok()?;
    let seconds: f64 = sec_str.trim().parse().ok()?;
    if !(0.0..60.0).contains(&seconds) || minutes < 0.0 {
        return None;
    }
    Some(minutes * 60.0 + seconds)
}

/// 从文件加载歌词（自动识别 UTF-8；BOM 容错）
pub fn load_lrc(path: &Path) -> Result<Lyrics, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("读取歌词失败: {e}"))?;
    // 去 UTF-8 BOM
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
    let content = String::from_utf8_lossy(bytes);
    Ok(parse_lrc(&content))
}

/// 为音频文件查找同名侧载歌词文件。
///
/// 依次尝试：`song.flac` → `song.lrc` / `song.Lrc` / `song.LRC` / `song.txt`
pub fn find_lrc_file(audio_path: &Path) -> Option<PathBuf> {
    let stem = audio_path.file_stem()?;
    let dir = audio_path.parent()?;
    for ext in ["lrc", "Lrc", "LRC", "txt"] {
        let candidate = dir.join(stem).with_extension(ext);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
[ti:测试歌曲]
[ar:测试歌手]
[al:测试专辑]
[00:01.00]第一行
[00:05.50]第二行
[00:10.00][01:00.00]重复行
[01:30.25]第三行
";

    #[test]
    fn parse_basic() {
        let l = parse_lrc(SAMPLE);
        assert_eq!(l.title.as_deref(), Some("测试歌曲"));
        assert_eq!(l.artist.as_deref(), Some("测试歌手"));
        assert_eq!(l.album.as_deref(), Some("测试专辑"));
        // 4 个时间标签行，其中一行双标签 → 5 行
        assert_eq!(l.lines.len(), 5);
        assert!((l.lines[0].time_secs - 1.0).abs() < 1e-9);
        assert_eq!(l.lines[0].text, "第一行");
    }

    #[test]
    fn multi_timestamp_expands_sorted() {
        let l = parse_lrc(SAMPLE);
        // 重复行展开为 10.0 和 60.0，整体按时间排序
        let times: Vec<f64> = l.lines.iter().map(|x| x.time_secs).collect();
        let mut sorted = times.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(times, sorted, "歌词行应按时间升序");
        assert!(times.contains(&10.0));
        assert!(times.contains(&60.0));
    }

    #[test]
    fn line_at_binary_search() {
        let l = parse_lrc(SAMPLE);
        assert_eq!(l.line_at(0.5), None, "第一行之前应无歌词");
        assert_eq!(l.line_at(1.0), Some(0));
        assert_eq!(l.line_at(3.0), Some(0), "行间应取前一行");
        assert_eq!(l.line_at(5.5), Some(1));
        assert_eq!(l.line_at(999.0), Some(l.lines.len() - 1));
    }

    #[test]
    fn offset_shifts_times() {
        let l = parse_lrc("[offset:500]\n[00:10.00]行\n");
        // offset +500ms = 提前 0.5s
        assert!((l.lines[0].time_secs - 9.5).abs() < 1e-9);

        let l2 = parse_lrc("[offset:-1000]\n[00:00.30]行\n");
        // 负 offset 延后，但不小于 0
        assert!((l2.lines[0].time_secs - 1.3).abs() < 1e-9);
    }

    #[test]
    fn milliseconds_three_digits() {
        let l = parse_lrc("[00:02.123]行\n");
        assert!((l.lines[0].time_secs - 2.123).abs() < 1e-9);
    }

    #[test]
    fn empty_text_lines_kept_as_markers() {
        // 空文本时间标签常用于表示"间奏无歌词"，仍占位
        let l = parse_lrc("[00:01.00]有词\n[00:05.00]\n");
        assert_eq!(l.lines.len(), 2);
        assert_eq!(l.lines[1].text, "");
    }

    #[test]
    fn invalid_timestamp_ignored() {
        let l = parse_lrc("[99:99.99]坏标签\n[00:03.00]好标签\n");
        assert_eq!(l.lines.len(), 1);
        assert_eq!(l.lines[0].text, "好标签");
    }

    #[test]
    fn find_lrc_sidecar() {
        let dir = std::env::temp_dir().join("wavelink_lrc_test");
        std::fs::create_dir_all(&dir).unwrap();
        let audio = dir.join("song.flac");
        let lrc = dir.join("song.lrc");
        std::fs::write(&audio, b"fake").unwrap();
        std::fs::write(&lrc, b"[00:01.00]hi\n").unwrap();

        assert_eq!(find_lrc_file(&audio), Some(lrc.clone()));
        // 加载验证
        let loaded = load_lrc(&lrc).unwrap();
        assert_eq!(loaded.lines[0].text, "hi");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn find_lrc_none_when_absent() {
        let dir = std::env::temp_dir().join("wavelink_lrc_absent");
        std::fs::create_dir_all(&dir).unwrap();
        let audio = dir.join("nope.flac");
        std::fs::write(&audio, b"fake").unwrap();
        assert_eq!(find_lrc_file(&audio), None);
        std::fs::remove_dir_all(&dir).ok();
    }
}
