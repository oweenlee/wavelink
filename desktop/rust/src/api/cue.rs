//! 桌面端 CUE 分轨解析 FFI
//!
//! 扫描期解析 `.cue` 分轨表：整轨镜像（APE/FLAC/WAV）拆成逐首虚拟曲目
//! 进入曲库。播放时 Dart 侧用 `wavelink_play_queue_at_json` 从指定分轨
//! 起播（core 的 resolve_entries 会自动展开 .cue 并遵循 start/end 边界）。
//!
//! 与 mobile `api::cue::parse_cue_file` 的差异：桌面版接收**原始字节 +
//! 基准目录**。mobile 版经 `parse_cue` 按 UTF-8 读行，遇到 GBK 编码的
//! cue（中文/日文抓轨常见）会因非法 UTF-8 直接失败；这里先试 UTF-8
//! （剥 BOM），失败回退 GBK 解码。FILE 相对路径按 [base_dir] 转绝对，
//! 与 core `resolve_entries` 的「cue 父目录 + 相对路径」语义一致。

use std::path::Path;

use flutter_rust_bridge::frb;

/// CUE 音轨
pub struct CueTrackResult {
    pub num: String,
    pub title: Option<String>,
    pub performer: Option<String>,
    /// INDEX 01 在音频文件中的起始时间（秒）
    pub start_secs: f64,
    /// PREGAP 时长（秒），虚拟静音，不存在于音频文件中
    pub pregap_secs: f64,
}

/// CUE 文件条目（对应一个物理音频文件）
pub struct CueFileResult {
    /// 绝对路径（相对声明已按 base_dir 解析）
    pub path: String,
    pub tracks: Vec<CueTrackResult>,
}

/// CUE 分轨解析结果
pub struct CueSheetResult {
    pub title: Option<String>,
    pub performer: Option<String>,
    pub files: Vec<CueFileResult>,
}

/// 解析 .cue 文件字节，返回分轨表。
///
/// [data]：cue 文件原始字节（UTF-8 / GBK 均可）；
/// [base_dir]：cue 所在目录，FILE 声明的相对路径以此为基准转绝对。
#[frb]
pub fn parse_cue_bytes(data: Vec<u8>, base_dir: String) -> Result<CueSheetResult, String> {
    let text = decode_cue_text(&data)?;
    let sheet = audio_core::cue::parse_cue_str(&text)?;
    let base = Path::new(&base_dir);
    Ok(CueSheetResult {
        title: sheet.title,
        performer: sheet.performer,
        files: sheet
            .files
            .into_iter()
            .map(|f| {
                let abs = {
                    let p = Path::new(&f.path);
                    if p.is_absolute() {
                        f.path.clone()
                    } else {
                        base.join(p).to_string_lossy().to_string()
                    }
                };
                CueFileResult {
                    path: abs,
                    tracks: f
                        .tracks
                        .into_iter()
                        .map(|t| CueTrackResult {
                            num: t.num,
                            title: t.title,
                            performer: t.performer,
                            start_secs: t.start_secs,
                            pregap_secs: t.pregap_secs,
                        })
                        .collect(),
                }
            })
            .collect(),
    })
}

/// cue 文本解码：先 UTF-8（剥 BOM），非法则回退 GBK（中文抓轨常见编码）。
fn decode_cue_text(data: &[u8]) -> Result<String, String> {
    let no_bom = data.strip_prefix(b"\xef\xbb\xbf").unwrap_or(data);
    if let Ok(s) = std::str::from_utf8(no_bom) {
        return Ok(s.to_string());
    }
    let (cow, _enc, had_errors) = encoding_rs::GBK.decode(no_bom);
    if had_errors {
        return Err("CUE 文本既非 UTF-8 也非 GBK，无法解码".into());
    }
    Ok(cow.into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_cue_text_utf8_with_bom() {
        let mut data = b"\xef\xbb\xbf".to_vec();
        data.extend_from_slice("TITLE \"专辑\"".as_bytes());
        assert_eq!(decode_cue_text(&data).unwrap(), "TITLE \"专辑\"");
    }

    #[test]
    fn decode_cue_text_gbk_fallback() {
        // 「专辑」的 GBK 字节（非法 UTF-8 → 必走 GBK 分支）
        let gbk = [0xD7, 0xA8, 0xBC, 0xAD];
        let text = decode_cue_text(&gbk).unwrap();
        assert_eq!(text, "专辑");
    }
}
