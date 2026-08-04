//! CUE 分轨解析。将 `.cue` 文件解析为音轨列表（含曲名、艺术家、起始时间）。

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

/// CUE 音轨
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CueTrack {
    /// 轨号（如 "01", "02"）
    pub num: String,
    /// 曲名
    pub title: Option<String>,
    /// 艺术家
    pub performer: Option<String>,
    /// INDEX 01 在音频文件中的起始时间（秒）
    pub start_secs: f64,
    /// PREGAP 时长（秒），虚拟静音，不存在于音频文件中
    pub pregap_secs: f64,
}

/// CUE 文件条目（对应一个物理音频文件）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CueFile {
    /// 音频文件路径（CUE 中声明的相对/绝对路径）
    pub path: String,
    /// 该文件包含的音轨
    pub tracks: Vec<CueTrack>,
}

/// CUE 分轨表顶层结构
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CueSheet {
    /// 整碟标题
    pub title: Option<String>,
    /// 整碟艺术家
    pub performer: Option<String>,
    /// 音频文件列表
    pub files: Vec<CueFile>,
}

impl CueSheet {
    /// 展平所有音轨，返回 `(音频文件路径, 音轨)` 列表
    pub fn all_tracks(&self) -> Vec<(&str, &CueTrack)> {
        let mut result = Vec::new();
        for file in &self.files {
            for track in &file.tracks {
                result.push((file.path.as_str(), track));
            }
        }
        result
    }
}

/// 将 CUE 时间戳 `mm:ss:ff` 转换为秒（75 帧/秒）
fn timestamp_to_secs(ts: &str) -> Result<f64, String> {
    let parts: Vec<&str> = ts.split(':').collect();
    if parts.len() != 3 {
        return Err(format!("时间戳格式无效: {ts}"));
    }
    let mm: u32 = parts[0]
        .parse()
        .map_err(|_| format!("分钟解析失败: {}", parts[0]))?;
    let ss: u32 = parts[1]
        .parse()
        .map_err(|_| format!("秒解析失败: {}", parts[1]))?;
    let ff: u32 = parts[2]
        .parse()
        .map_err(|_| format!("帧解析失败: {}", parts[2]))?;
    if ff >= 75 {
        return Err(format!("帧数超出范围 (0-74): {ff}"));
    }
    Ok(mm as f64 * 60.0 + ss as f64 + ff as f64 / 75.0)
}

/// 解析 CUE 文件
pub fn parse_cue(path: &Path) -> Result<CueSheet, String> {
    let file = File::open(path).map_err(|e| format!("无法打开 CUE 文件: {e}"))?;
    let mut reader = BufReader::new(file);
    parse_cue_reader(&mut reader)
}

/// 从字符串解析 CUE
pub fn parse_cue_str(data: &str) -> Result<CueSheet, String> {
    let mut reader = BufReader::new(data.as_bytes());
    parse_cue_reader(&mut reader)
}

/// 从行中解析第一个引号字符串或第一个单词
fn extract_first_value(args: &str) -> Result<String, String> {
    let s = args.trim();
    if s.is_empty() {
        return Err("缺少值".into());
    }
    if let Some(rest) = s.strip_prefix('"') {
        let end = rest
            .find('"')
            .ok_or_else(|| "未闭合的引号".to_string())?;
        Ok(rest[..end].to_string())
    } else {
        Ok(s.split_whitespace()
            .next()
            .unwrap_or("")
            .to_string())
    }
}

fn parse_cue_reader(reader: &mut dyn BufRead) -> Result<CueSheet, String> {
    let mut sheet = CueSheet {
        title: None,
        performer: None,
        files: Vec::new(),
    };
    let mut cur_file_idx: Option<usize> = None;
    let mut cur_track: Option<CueTrack> = None;

    for line_result in reader.lines() {
        let line = line_result.map_err(|e| format!("读取 CUE 失败: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let cmd_end = trimmed
            .find(|c: char| c.is_whitespace())
            .unwrap_or(trimmed.len());
        let cmd = &trimmed[..cmd_end];
        let args = trimmed[cmd_end..].trim();

        match cmd.to_uppercase().as_str() {
            "REM" | "CATALOG" | "CDTEXTFILE" | "SONGWRITER" | "FLAGS" | "ISRC" => {}
            "TITLE" => {
                if let Ok(val) = extract_first_value(args) {
                    if cur_track.is_some() {
                        if let Some(ref mut t) = cur_track {
                            t.title = Some(val);
                        }
                    } else {
                        sheet.title = Some(val);
                    }
                }
            }
            "PERFORMER" => {
                if let Ok(val) = extract_first_value(args) {
                    if cur_track.is_some() {
                        if let Some(ref mut t) = cur_track {
                            t.performer = Some(val);
                        }
                    } else {
                        sheet.performer = Some(val);
                    }
                }
            }
            "FILE" => {
                flush_track(&mut sheet, &mut cur_file_idx, &mut cur_track);
                if let Ok(path) = extract_first_value(args) {
                    sheet.files.push(CueFile {
                        path,
                        tracks: Vec::new(),
                    });
                    cur_file_idx = Some(sheet.files.len() - 1);
                }
            }
            "TRACK" => {
                flush_track(&mut sheet, &mut cur_file_idx, &mut cur_track);
                let parts: Vec<&str> = args.split_whitespace().collect();
                let num = parts.first().unwrap_or(&"").to_string();
                cur_track = Some(CueTrack {
                    num,
                    title: None,
                    performer: None,
                    start_secs: 0.0,
                    pregap_secs: 0.0,
                });
            }
            "INDEX" => {
                let parts: Vec<&str> = args.split_whitespace().collect();
                if parts.len() >= 2 && parts[0] == "01" {
                    if let Ok(secs) = timestamp_to_secs(parts[1]) {
                        if let Some(ref mut t) = cur_track {
                            // INDEX 01 是真实音频起始位置，PREGAP 是虚拟静音，不从文件中扣除
                            t.start_secs = secs;
                        }
                    }
                }
            }
            "PREGAP" => {
                let ts = args.split_whitespace().next().unwrap_or("");
                if let Ok(secs) = timestamp_to_secs(ts) {
                    if let Some(ref mut t) = cur_track {
                        t.pregap_secs = secs;
                    }
                }
            }
            "POSTGAP" => {}
            _ => {}
        }
    }

    flush_track(&mut sheet, &mut cur_file_idx, &mut cur_track);

    if sheet.files.is_empty() {
        return Err("CUE 文件中未找到任何 FILE 条目".into());
    }
    Ok(sheet)
}

fn flush_track(
    sheet: &mut CueSheet,
    cur_file_idx: &mut Option<usize>,
    cur_track: &mut Option<CueTrack>,
) {
    if let Some(track) = cur_track.take() {
        if let Some(idx) = *cur_file_idx {
            sheet.files[idx].tracks.push(track);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_timestamp_to_secs() {
        assert!((timestamp_to_secs("00:00:00").unwrap() - 0.0).abs() < 1e-9);
        assert!((timestamp_to_secs("00:01:00").unwrap() - 1.0).abs() < 1e-9);
        assert!((timestamp_to_secs("01:00:00").unwrap() - 60.0).abs() < 1e-9);
        assert!((timestamp_to_secs("01:30:00").unwrap() - 90.0).abs() < 1e-9);
        assert!((timestamp_to_secs("00:00:01").unwrap() - 1.0 / 75.0).abs() < 1e-9);
        assert!((timestamp_to_secs("04:32:18").unwrap() - 272.24).abs() < 1e-9);
        assert!(timestamp_to_secs("").is_err());
        assert!(timestamp_to_secs("abc").is_err());
        assert!(timestamp_to_secs("00:00:75").is_err());
    }

    #[test]
    fn test_parse_simple_cue() {
        let cue = r#"REM GENRE "Alternative"
REM DATE 1991
PERFORMER "My Bloody Valentine"
TITLE "Loveless"
FILE "My Bloody Valentine - Loveless.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Only Shallow"
    PERFORMER "My Bloody Valentine"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Loomer"
    INDEX 01 02:33:00
  TRACK 03 AUDIO
    TITLE "Touched"
    INDEX 01 04:56:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        assert_eq!(sheet.title.unwrap(), "Loveless");
        assert_eq!(sheet.performer.unwrap(), "My Bloody Valentine");
        assert_eq!(sheet.files.len(), 1);
        assert_eq!(sheet.files[0].path, "My Bloody Valentine - Loveless.wav");
        assert_eq!(sheet.files[0].tracks.len(), 3);
        assert_eq!(sheet.files[0].tracks[0].num, "01");
        assert_eq!(sheet.files[0].tracks[0].title.as_deref(), Some("Only Shallow"));
        assert_eq!(sheet.files[0].tracks[0].performer.as_deref(), Some("My Bloody Valentine"));
        assert!((sheet.files[0].tracks[0].start_secs - 0.0).abs() < 1e-9);
        assert!((sheet.files[0].tracks[1].start_secs - 153.0).abs() < 1e-9);
        assert!((sheet.files[0].tracks[2].start_secs - 296.0).abs() < 1e-9);
    }

    #[test]
    fn test_multiple_files() {
        let cue = r#"FILE "cd1.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Song 1"
    INDEX 01 00:00:00
FILE "cd2.wav" WAVE
  TRACK 02 AUDIO
    TITLE "Song 2"
    INDEX 01 00:00:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        assert_eq!(sheet.files.len(), 2);
        assert_eq!(sheet.files[0].path, "cd1.wav");
        assert_eq!(sheet.files[1].path, "cd2.wav");
        assert_eq!(sheet.files[0].tracks.len(), 1);
        assert_eq!(sheet.files[1].tracks.len(), 1);
    }

    #[test]
    fn test_pregap() {
        let cue = r#"FILE "test.wav" WAVE
  TRACK 01 AUDIO
    TITLE "With Pregap"
    PREGAP 00:02:00
    INDEX 01 00:30:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        let track = &sheet.files[0].tracks[0];
        // INDEX 01 = 30s 是真实音频起始，PREGAP 是虚拟静音不影响 start_secs
        assert!((track.start_secs - 30.0).abs() < 1e-9);
        assert!((track.pregap_secs - 2.0).abs() < 1e-9);
    }

    #[test]
    fn test_no_tracks() {
        let cue = r#"REM empty
FILE "silence.wav" WAVE
"#;
        let sheet = parse_cue_str(cue).unwrap();
        assert_eq!(sheet.files.len(), 1);
        assert_eq!(sheet.files[0].tracks.len(), 0);
    }

    #[test]
    fn test_all_tracks_flatten() {
        let cue = r#"FILE "a.wav" WAVE
  TRACK 01 AUDIO
    TITLE "A1"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "A2"
    INDEX 01 01:00:00
FILE "b.wav" WAVE
  TRACK 03 AUDIO
    TITLE "B1"
    INDEX 01 00:00:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        let all = sheet.all_tracks();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].0, "a.wav");
        assert_eq!(all[0].1.title.as_deref(), Some("A1"));
        assert_eq!(all[1].0, "a.wav");
        assert_eq!(all[1].1.title.as_deref(), Some("A2"));
        assert_eq!(all[2].0, "b.wav");
        assert_eq!(all[2].1.title.as_deref(), Some("B1"));
    }

    #[test]
    fn test_empty_cue() {
        let result = parse_cue_str("");
        assert!(result.is_err());
    }

    #[test]
    fn test_unicode() {
        let cue = r#"TITLE "マジコカタストロフィ"
PERFORMER "アーティスト"
FILE "test.wav" WAVE
  TRACK 01 AUDIO
    TITLE "曲名"
    PERFORMER "歌手"
    INDEX 01 00:00:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        assert_eq!(sheet.title.as_deref(), Some("マジコカタストロフィ"));
        assert_eq!(sheet.files[0].tracks[0].title.as_deref(), Some("曲名"));
        assert_eq!(sheet.files[0].tracks[0].performer.as_deref(), Some("歌手"));
    }

    #[test]
    fn test_disc_level_only() {
        let cue = r#"TITLE "Greatest Hits"
PERFORMER "Various"
FILE "compilation.wav" WAVE
  TRACK 01 AUDIO
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 01 03:00:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        assert_eq!(sheet.title.as_deref(), Some("Greatest Hits"));
        assert_eq!(sheet.performer.as_deref(), Some("Various"));
        // 音轨级别的 title/performer 应为 None
        let tracks = sheet.all_tracks();
        assert!(tracks[0].1.title.is_none());
        assert!(tracks[0].1.performer.is_none());
    }

    #[test]
    fn test_file_with_special_chars_in_path() {
        let cue = r#"FILE "My Music/Life & Death/01 - Intro.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Intro"
    INDEX 01 00:00:00
"#;
        let sheet = parse_cue_str(cue).unwrap();
        assert_eq!(
            sheet.files[0].path,
            "My Music/Life & Death/01 - Intro.flac"
        );
    }
}
