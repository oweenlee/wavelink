use std::fs;
#[allow(unused_imports)]
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use encoding_rs::GBK;
use image::{imageops::FilterType, ImageFormat};
use lofty::file::AudioFile;
use lofty::file::TaggedFileExt;
use lofty::read_from_path;
use lofty::tag::Accessor;
use tracing::{debug, info, warn};

use super::db::{LibraryDb, Track};

/// 支持的音频扩展名
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "aac", "m4a", "m4b", "mp4",
    "wma", "dsf", "dff", "ape", "opus", "aiff", "aif", "wv",
];

/// 封面最大尺寸（像素），超出的缩小到此值
const COVER_MAX_SIZE: u32 = 256;

/// 将原始图片数据解码 → 缩放到 COVER_MAX_SIZE → 编码为 JPEG base64
/// 解码失败时回退到原图 base64（不做缩放）
fn resize_and_encode(data: &[u8]) -> Option<String> {
    match image::load_from_memory(data) {
        Ok(img) => {
            let resized = if img.width() > COVER_MAX_SIZE || img.height() > COVER_MAX_SIZE {
                img.resize(COVER_MAX_SIZE, COVER_MAX_SIZE, FilterType::Lanczos3)
            } else {
                img
            };
            let mut buf = std::io::Cursor::new(Vec::new());
            resized.write_to(&mut buf, ImageFormat::Jpeg).ok()?;
            let b64 = base64::engine::general_purpose::STANDARD.encode(buf.get_ref());
            Some(format!("data:image/jpeg;base64,{b64}"))
        }
        Err(_) => {
            // 解码失败（如罕见格式），回退到原图 base64
            let b64 = base64::engine::general_purpose::STANDARD.encode(data);
            Some(format!("data:image;base64,{b64}"))
        }
    }
}

/// 从文件名推测的信息（标签缺失时回退）
struct InferredInfo {
    title: Option<String>,
    artist: Option<String>,
    track_number: Option<i32>,
}

/// 修复用 Latin-1 编码写入的中文 ID3 标签（国内常见工具行为）
/// Latin-1 → UTF-8 转换会变成单字节扩展字符，重新解释为 GBK 得到正确中文
fn fix_gbk_tag(s: &str) -> String {
    // 如果已有中文，说明是正确的
    if s.chars().any(|c| ('\u{4E00}'..='\u{9FFF}').contains(&c) || ('\u{3400}'..='\u{4DBF}').contains(&c)) {
        return s.to_string();
    }
    // 检查是否存在 Latin-1 扩展字符 (0x80-0xFF)
    let has_high = s.chars().any(|c| ('\u{0080}'..='\u{00FF}').contains(&c));
    if !has_high { return s.to_string(); }

    // 将 Unicode 编码范围内的字符映射回原始字节
    let bytes: Vec<u8> = s.chars()
        .filter(|&c| c as u32 <= 0xFF)
        .map(|c| if c as u32 <= 0xFF { c as u8 } else { b'?' })
        .filter(|&b| b >= 0x80 || b.is_ascii_graphic() || b == b' ')
        .collect();
    if bytes.is_empty() { return s.to_string(); }

    let (cow, _, had_errors) = GBK.decode(&bytes);
    if had_errors { s.to_string() } else { cow.into_owned() }
}

/// 解析常见文件名格式:
/// - "Artist - Title.ext"
/// - "01 - Title.ext"
/// - "01 Title.ext"
/// - "01_Artist_-_Title.ext"
fn infer_from_filename(stem: &str) -> InferredInfo {
    // 清理: 替换常见分隔符为空格
    let cleaned = stem
        .replace('_', " ")
        .replace('.', " ")
        .replace('-', " - ");
    let parts: Vec<&str> = cleaned.split(" - ").map(|s| s.trim()).filter(|s| !s.is_empty()).collect();

    let mut info = InferredInfo { title: None, artist: None, track_number: None };

    match parts.len() {
        1 => {
            // 只有文件名 → 去掉前缀数字
            let s = parts[0];
            let without_num = s.trim_start_matches(|c: char| c.is_ascii_digit() || c == ' ' || c == '.' || c == '-').trim();
            if !without_num.is_empty() && without_num != s {
                // "01 Title" → track=1, title="Title"
                let num: i32 = s.split_whitespace().next()
                    .and_then(|w| w.parse().ok()).unwrap_or(0);
                info.track_number = Some(num);
                info.title = Some(without_num.to_string());
            } else {
                info.title = Some(s.to_string());
            }
        }
        2 => {
            // "Artist - Title" or "01 - Title"
            let first = parts[0].trim();
            let second = parts[1].trim();
            if let Ok(num) = first.parse::<i32>() {
                info.track_number = Some(num);
                info.title = Some(second.to_string());
            } else if first.len() < 20 {
                // 看起来像艺术家名
                info.artist = Some(first.to_string());
                info.title = Some(second.to_string());
            } else {
                info.title = Some(stem.to_string());
            }
        }
        3 => {
            // "Artist - Album - Title" or "01 - Artist - Title"
            let first = parts[0].trim();
            let second = parts[1].trim();
            let third = parts[2].trim();
            if let Ok(num) = first.parse::<i32>() {
                info.track_number = Some(num);
                if second.len() < 20 {
                    info.artist = Some(second.to_string());
                }
                info.title = Some(third.to_string());
            } else {
                info.artist = Some(first.to_string());
                info.title = Some(third.to_string());
            }
        }
        _ => {
            info.title = Some(parts.last().unwrap_or(&stem).to_string());
        }
    }

    // 去掉字符串中可能残留的序号前缀（如 "01. Title" → "Title"）
    if let Some(ref title) = info.title {
        if let Some(cleaned) = strip_track_number(title) {
            info.title = Some(cleaned);
        }
    }

    info
}

/// 去掉标题开头的 "01." "01 " 等音轨号前缀
fn strip_track_number(s: &str) -> Option<String> {
    let s = s.trim();
    let after_num = s.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.' || c == ' ' || c == '-' || c == '_');
    if after_num.is_empty() || after_num.len() == s.len() { return None; }
    let result = after_num.trim();
    if result.is_empty() { None } else { Some(result.to_string()) }
}

/// 曲库扫描器
pub struct Scanner;

impl Scanner {
    /// 递归扫描目录，读取标签并写入数据库
    pub fn scan_directory(db: &LibraryDb, dir: &Path) -> Result<ScannerResult, String> {
        if !dir.is_dir() {
            return Err(format!("路径不是目录: {}", dir.display()));
        }

        info!("开始扫描目录: {}", dir.display());
        db.reset_missing_flags().map_err(|e| format!("重置标记失败: {e}"))?;

        let mut scanned = 0u64;
        let mut errors = 0u64;

        walk_dir(dir, &mut |path| {
            let ext = path.extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_lowercase());
            if let Some(ref ext) = ext {
                if AUDIO_EXTENSIONS.contains(&ext.as_str()) {
                    match scan_file(&path) {
                        Ok(Some(track)) => {
                            if let Err(e) = db.upsert_track(&track) {
                                warn!("写入数据库失败 {}: {e}", path.display());
                                errors += 1;
                            } else {
                                scanned += 1;
                            }
                        }
                        Ok(None) => {} // 跳过（非音频文件）
                        Err(e) => {
                            warn!("读取标签失败 {}: {e}", path.display());
                            errors += 1;
                        }
                    }
                }
            }
        });

        let removed = db.remove_missing_tracks().unwrap_or_default();
        info!(
            "扫描完成: 新增/更新 {scanned}, 错误 {errors}, 移除 {}",
            removed.len()
        );
        Result::Ok(ScannerResult { scanned, errors, removed: removed.len() as u64 })
    }

    /// 扫描单个文件
    pub fn scan_file(path: &Path) -> Result<Option<Track>, String> {
        scan_file(path)
    }
}

/// 扫描结果统计
#[derive(Debug, Clone)]
pub struct ScannerResult {
    pub scanned: u64,
    pub errors: u64,
    pub removed: u64,
}

fn scan_file(path: &Path) -> Result<Option<Track>, String> {
    // 读取文件元数据
    let meta = fs::metadata(path).map_err(|e| format!("读取文件信息失败: {e}"))?;
    let file_size = meta.len() as i64;
    let file_modified = meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);

    // 获取扩展名作为格式
    let format = path.extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_lowercase());

    // 读取标签
    let tagged = match read_from_path(path) {
        Ok(f) => f,
        Err(e) => {
            debug!("lofty 无法读取 {}: {e}", path.display());
            return Ok(None);
        }
    };

    // 取主标签（优先 ID3v2/FLAC/Vorbis）
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());

    // 提取封面（取第一张图片，base64 编码）
    let cover_base64 = tag.and_then(|t| {
        t.pictures().first().and_then(|pic| resize_and_encode(pic.data()))
    });

    let file_stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("?");
    let inferred = infer_from_filename(file_stem);

    let track = Track {
        id: 0,
        path: path.to_string_lossy().into_owned(),
        title: tag.and_then(|t| t.title().map(|s| fix_gbk_tag(&s))).or_else(|| {
            inferred.title.or(Some(file_stem.to_string()))
        }),
        artist: tag.and_then(|t| t.artist().map(|s| fix_gbk_tag(&s))).or_else(|| {
            if inferred.artist.is_some() { inferred.artist } else { Some("未知艺术家".into()) }
        }),
        album: tag.and_then(|t| t.album().map(|s| fix_gbk_tag(&s))).or_else(|| Some("未知专辑".into())),
        album_artist: None,
        track_number: tag.and_then(|t| t.get_string(lofty::tag::ItemKey::TrackNumber).and_then(|s| s.parse::<i32>().ok())).or(inferred.track_number),
        disc_number: tag.and_then(|t| t.get_string(lofty::tag::ItemKey::DiscNumber).and_then(|s| s.parse::<i32>().ok())),
        year: tag.and_then(|t| t.get_string(lofty::tag::ItemKey::Year).and_then(|s| s.parse::<i32>().ok())),
        genre: tag.and_then(|t| t.genre().map(|s| fix_gbk_tag(&s))),
            duration: {
                let d = tagged.properties().duration().as_secs_f64();
                if d > 0.1 { Some(d) } else { None }
            },
        sample_rate: tagged.properties().sample_rate().map(|r| r as i32),
        channels: tagged.properties().channels().map(|c| c as i32),
        format,
        file_size: Some(file_size),
        file_modified,
        date_added: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64,
        play_count: 0,
        last_played: None,
        rating: 0,
        missing: false,
        cover_base64,
        track_gain: None,
    };

    debug!("扫描: {} | {} - {}", track.path, track.artist.as_deref().unwrap_or("?"), track.title.as_deref().unwrap_or("?"));
    Ok(Some(track))
}

/// 从音频文件直接读取封面（data URI 格式），不依赖数据库
///
/// 支持的格式：
/// - ID3v2（MP3）APIC 帧
/// - FLAC METADATA_BLOCK_PICTURE
/// - MP4/M4A、WMA 等请使用 lofty（scan_file）
pub fn get_file_cover(path: &Path) -> Result<Option<String>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("读取文件失败: {e}"))?;
    if bytes.len() < 8 {
        return Ok(None);
    }

    // ── FLAC：查找 METADATA_BLOCK_PICTURE ──
    if &bytes[0..4] == b"fLaC" {
        return extract_flac_cover(&bytes);
    }

    // ── MP3/ID3v2 ──
    if &bytes[0..3] != b"ID3" {
        return Ok(None);
    }

    extract_id3v2_apic(&bytes)
}

/// 从 FLAC 文件提取封面（METADATA_BLOCK_PICTURE）
fn extract_flac_cover(bytes: &[u8]) -> Result<Option<String>, String> {
    let mut pos: usize = 4; // skip "fLaC"
    loop {
        if pos + 4 > bytes.len() {
            return Ok(None);
        }
        let is_last = (bytes[pos] & 0x80) != 0;
        let block_type = bytes[pos] & 0x7f;
        let block_len = u32::from_be_bytes([0, bytes[pos + 1], bytes[pos + 2], bytes[pos + 3]]) as usize;
        pos += 4;

        if pos + block_len > bytes.len() {
            return Ok(None);
        }

        // METADATA_BLOCK_PICTURE type = 6
        if block_type == 6 {
            let data = &bytes[pos..pos + block_len];
            // 跳过 picture type (4 bytes)
            if data.len() < 4 { return Ok(None); }
            // MIME type (null-terminated string)
            let mime_end = data[4..].iter().position(|&b| b == 0).unwrap_or(data.len() - 4);
            let desc_start = 4 + mime_end + 1;
            // 跳过 description (null-terminated)
            let desc_end = data[desc_start..].iter().position(|&b| b == 0).unwrap_or(data.len() - desc_start);
            let img_start = desc_start + desc_end + 1;
            // 跳过 width (4), height (4), color_depth (4), colors_used (4) = 16 bytes
            let _pixel_data_start = img_start + 16;
            // 跳过 picture length (4 bytes before pixel data)
            let _pic_len = u32::from_be_bytes(
                data[img_start..img_start + 4].try_into().unwrap_or([0; 4]),
            );
            // Actually the spec says: picture type(4) + mime + null + desc + null + width(4) + height(4) + color_depth(4) + colors_used(4) + pic_len(4) + pic_data
            // Let me redo this properly:
            // offset 0: picture type (u32 BE)
            // offset 4: MIME type (null-terminated string)
            let mime_end2 = data[4..].iter().position(|&b| b == 0).unwrap_or(0);
            let desc_start2 = 4 + mime_end2 + 1;
            // offset desc_start2: description (null-terminated)
            let desc_end2 = data[desc_start2..].iter().position(|&b| b == 0).unwrap_or(data.len() - desc_start2);
            let pixel_meta_start = desc_start2 + desc_end2 + 1;
            // pixel_meta: width(4) + height(4) + color_depth(4) + colors_used(4) = 16 bytes
            // then: picture_data_length(4) + picture_data
            if pixel_meta_start + 20 > data.len() {
                return Ok(None);
            }
            let pic_data_len = u32::from_be_bytes(
                data[pixel_meta_start + 16..pixel_meta_start + 20].try_into().unwrap_or([0; 4]),
            ) as usize;
            let pic_data_start = pixel_meta_start + 20;
            if pic_data_start + pic_data_len > data.len() {
                return Ok(None);
            }
            let img_data = &data[pic_data_start..pic_data_start + pic_data_len];
            return Ok(resize_and_encode(img_data));
        }

        pos += block_len;
        if is_last {
            break;
        }
    }
    Ok(None)
}

/// 从 ID3v2 标签提取 APIC 帧中的封面
fn extract_id3v2_apic(bytes: &[u8]) -> Result<Option<String>, String> {
    if bytes.len() < 10 || &bytes[0..3] != b"ID3" {
        return Ok(None);
    }

    let tag_size = ((bytes[6] as usize) << 21)
        | ((bytes[7] as usize) << 14)
        | ((bytes[8] as usize) << 7)
        | (bytes[9] as usize);

    let mut pos = 10;
    let end = 10 + tag_size;

    while pos + 10 <= end {
        let frame_id = &bytes[pos..pos + 4];
        let frame_size = u32::from_be_bytes([bytes[pos + 4], bytes[pos + 5], bytes[pos + 6], bytes[pos + 7]]) as usize;

        // 结束标记
        if frame_id == [0, 0, 0, 0] {
            break;
        }

        // 找到 APIC 帧
        if &frame_id == b"APIC" {
            if pos + 10 + frame_size > bytes.len() {
                break;
            }
            let frame_data = &bytes[pos + 10..pos + 10 + frame_size];
            let _encoding = frame_data[0];

            // 找 MIME 类型（null 结尾）
            let mut mime_end = 1;
            while mime_end < frame_data.len() && frame_data[mime_end] != 0 {
                mime_end += 1;
            }
            if mime_end + 1 >= frame_data.len() {
                break;
            }
            let _mime = &frame_data[1..mime_end];
            let _pic_type = frame_data[mime_end + 1];

            // 跳过描述字段
            let mut desc_start = mime_end + 2;
            if _encoding == 0 || _encoding == 2 {
                while desc_start < frame_data.len() && frame_data[desc_start] != 0 {
                    desc_start += 1;
                }
                desc_start += 1;
            } else if _encoding == 1 {
                while desc_start + 1 < frame_data.len() && !(frame_data[desc_start] == 0 && frame_data[desc_start + 1] == 0) {
                    desc_start += 1;
                }
                desc_start += 2;
            } else if _encoding == 3 {
                while desc_start < frame_data.len() && frame_data[desc_start] != 0 {
                    desc_start += 1;
                }
                desc_start += 1;
            } else {
                break;
            }

            if desc_start < frame_data.len() {
                let img_data = &frame_data[desc_start..];
                return Ok(resize_and_encode(img_data));
            }
            break;
        }

        pos += 10 + frame_size;
    }

    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_file_cover_id3v2() {
        // 构造一个最小 ID3v2 文件：ID3v2.3 头 + APIC 帧（1×1 红色像素 PNG）
        let png_data: &[u8] = &[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1×1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x36, 0x28, 0x19,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
            0xAE, 0x42, 0x60, 0x82,
        ];

        // APIC 帧体: encoding(1) + MIME("image/png" + null) + pic_type(3) + desc(null) + img_data
        let mut apic_body = Vec::new();
        apic_body.push(0x03); // UTF-8 encoding
        apic_body.extend_from_slice(b"image/png\x00");
        apic_body.push(3); // front cover
        apic_body.push(0); // empty description (null)
        apic_body.extend_from_slice(png_data);

        let frame_size = apic_body.len() as u32;
        // ID3v2.3 frame header: 4-byte ID + 4-byte size (BE) + 2-byte flags
        let mut frame = Vec::new();
        frame.extend_from_slice(b"APIC");
        frame.extend_from_slice(&frame_size.to_be_bytes());
        frame.extend_from_slice(&[0, 0]); // flags
        frame.extend_from_slice(&apic_body);

        // ID3v2.3 tag header: "ID3" + ver(3,0) + flags(0) + size (syncsafe)
        let tag_data_len = frame.len();
        let syncsafe = |n: usize| -> Vec<u8> {
            vec![
                ((n >> 21) & 0x7F) as u8,
                ((n >> 14) & 0x7F) as u8,
                ((n >> 7) & 0x7F) as u8,
                (n & 0x7F) as u8,
            ]
        };
        let mut file = Vec::new();
        file.extend_from_slice(b"ID3");
        file.push(3); // ver_major
        file.push(0); // ver_minor
        file.push(0); // flags
        file.extend_from_slice(&syncsafe(tag_data_len));
        file.extend_from_slice(&frame);

        // 写入临时文件
        let tmp = Path::new("/tmp/test_cover_synthetic.mp3");
        std::fs::write(tmp, &file).unwrap();

        let result = get_file_cover(tmp);
        assert!(result.is_ok(), "get_file_cover failed: {:?}", result);
        let cover = result.unwrap();
        assert!(cover.is_some(), "should have found a cover");
        assert!(cover.unwrap().starts_with("data:image;base64,"));

        let _ = std::fs::remove_file(tmp);
    }

    #[test]
    fn test_get_file_cover_no_id3() {
        // 没有 ID3v2 头的文件 → Ok(None)
        let tmp = Path::new("/tmp/test_cover_no_id3.mp3");
        std::fs::write(tmp, &[0xFF, 0xFB, 0x90, 0x00]).unwrap(); // MPEG sync
        let result = get_file_cover(tmp);
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
        let _ = std::fs::remove_file(tmp);
    }
}

/// 递归遍历目录
fn walk_dir(dir: &Path, cb: &mut impl FnMut(&PathBuf)) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => {
            warn!("读取目录失败 {}: {e}", dir.display());
            return;
        }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            // 跳过隐藏目录和系统目录
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if name.starts_with('.') || name == "System Volume Information" || name == "$RECYCLE.BIN" {
                continue;
            }
            walk_dir(&path, cb);
        } else if path.is_file() {
            cb(&path);
        }
    }
}


