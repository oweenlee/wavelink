use std::fs;
#[allow(unused_imports)]
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use encoding_rs::GBK;
use image::{imageops::FilterType, ImageFormat};
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
        .replace(['_', '.'], " ")
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
        // 串行化扫描：文件监控 / 手动重扫 / 分析可能同时触发。
        // 若不加锁, 两个并发扫描各自 reset+remove_missing 会互相删掉对方尚未入库的曲目
        let _guard = SCAN_LOCK.lock().map_err(|e| format!("扫描锁失败: {e}"))?;

        scan_directory_inner(db, dir)
    }

    /// 扫描单个文件
    pub fn scan_file(path: &Path) -> Result<Option<Track>, String> {
        scan_file(path)
    }
}

static SCAN_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn scan_directory_inner(db: &LibraryDb, dir: &Path) -> Result<ScannerResult, String> {
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
                if ext == "strm" {
                    // STRM 指针文件：解析内容指向的真实媒体，按真实音频收录
                    // ——本地路径元数据/封面/时长齐全，播放无感；http(s) URL
                    // 则收录为 URL 轨道，播放时由前端走「下载缓存再 play」链路。
                    match resolve_strm_target(path) {
                        Some(rs) => {
                            if let Some(url) = rs.url {
                                // STRM 指向 http(s) URL：收录为 URL 轨道。
                                // 无本地文件，元数据从 `#EXTINF` 兜底；
                                // 播放时由前端走「下载缓存再 play」链路。
                                let format = url
                                    .split('?')
                                    .next()
                                    .and_then(|p| p.rsplit('.').next())
                                    .map(|e| e.to_lowercase())
                                    .filter(|e| AUDIO_EXTENSIONS.contains(&e.as_str()));
                                let file_stem = url
                                    .split('?')
                                    .next()
                                    .and_then(|p| p.rsplit('/').next())
                                    .map(|s| s.to_string())
                                    .unwrap_or_else(|| "?".into());
                                let stem = file_stem.rsplit('.').next_back().unwrap_or(&file_stem).to_string();
                                let track = Track {
                                    id: 0,
                                    path: url.clone(),
                                    title: rs.extinf_title.clone().or(Some(stem)),
                                    artist: Some("未知艺术家".into()),
                                    album: Some("未知专辑".into()),
                                    album_artist: None,
                                    track_number: None,
                                    disc_number: None,
                                    year: None,
                                    genre: None,
                                    duration: rs.extinf_duration,
                                    sample_rate: None,
                                    channels: None,
                                    format,
                                    file_size: None,
                                    file_modified: None,
                                    date_added: SystemTime::now()
                                        .duration_since(UNIX_EPOCH)
                                        .unwrap_or_default()
                                        .as_secs() as i64,
                                    play_count: 0,
                                    last_played: None,
                                    rating: 0,
                                    missing: false,
                                    cover_base64: None,
                                    track_gain: None,
                                };
                                if let Err(e) = db.upsert_track(&track) {
                                    warn!("写入数据库失败 {}: {e}", url);
                                    errors += 1;
                                } else {
                                    scanned += 1;
                                }
                            } else if let Some(target) = rs.target {
                                match scan_file(&target) {
                                    Ok(Some(mut track)) => {
                                        // Kodi strm 库的 #EXTINF 行携带展示标题/时长：
                                        // 真实文件无标签时以它为兑底展示名（与 Kodi 一致）
                                        if let Some(t) = rs.extinf_title {
                                            track.title = Some(t);
                                        }
                                        if track.duration.is_none() {
                                            track.duration = rs.extinf_duration;
                                        }
                                        if let Err(e) = db.upsert_track(&track) {
                                            warn!("写入数据库失败 {}: {e}", target.display());
                                            errors += 1;
                                        } else {
                                            scanned += 1;
                                        }
                                    }
                                    Ok(None) => {} // 跳过（目标非音频）
                                    Err(e) => {
                                        warn!("读取标签失败 {}: {e}", target.display());
                                        errors += 1;
                                    }
                                }
                            }
                        },
                        None => {
                            warn!("STRM 目标不可用，跳过: {}", path.display());
                        }
                    }
                } else if AUDIO_EXTENSIONS.contains(&ext.as_str()) {
                    match scan_file(path) {
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

/// 扫描结果统计
#[derive(Debug, Clone)]
pub struct ScannerResult {
    pub scanned: u64,
    pub errors: u64,
    pub removed: u64,
}

/// 解析 .strm 指针内容 → 目标媒体路径。
/// strm 是纯文本，内容为一行指向真实媒体的路径：绝对路径直接用，
/// 相对路径相对 strm 文件所在目录解析（兼容 ./ 与 ../）。
/// 目标必须是本地音频文件（扩展名在 [AUDIO_EXTENSIONS] 内）且存在；
/// http(s) URL 目标同样收录为 URL 轨道（播放时由前端走下载缓存链路）。
/// STRM 解析结果：目标媒体路径 + Kodi 风格 `#EXTINF` 信息行携带的
/// 展示标题/时长（真实文件无标签时的兜底展示名）。
struct ResolvedStrm {
    target: Option<PathBuf>,
    /// http(s) URL 目标（target 为 None 时有效）
    url: Option<String>,
    extinf_title: Option<String>,
    extinf_duration: Option<f64>,
}

/// 解析 .strm 指针内容 → 目标媒体路径。
/// strm 是纯文本，内容为一行指向真实媒体的路径：绝对路径直接用，
/// 相对路径相对 strm 文件所在目录解析（兼容 ./ 与 ../）。
/// 目标必须是本地音频文件（扩展名在 [AUDIO_EXTENSIONS] 内）且存在；
/// http(s) URL 目标同样收录为 URL 轨道（播放时由前端走下载缓存链路）。
/// 顺带解析 `#EXTINF:秒数,标题` 信息行（Kodi strm 库惯例）。
fn resolve_strm_target(strm_path: &Path) -> Option<ResolvedStrm> {
    let content = fs::read_to_string(strm_path).ok()?;
    // 去 BOM/空白/注释行，取第一行有效内容（strm 规范为单行，容忍多行）；
    // `#EXTINF` 信息行携带展示标题/时长（其余 # 开头为注释）
    let mut extinf_title: Option<String> = None;
    let mut extinf_duration: Option<f64> = None;
    let mut line: Option<&str> = None;
    for raw in content.lines() {
        let l = raw.trim().trim_start_matches('\u{feff}');
        if l.is_empty() {
            continue;
        }
        if let Some(rest) = l.strip_prefix('#') {
            if let Some(body) = rest.strip_prefix("EXTINF:") {
                if let Some(comma) = body.find(',') {
                    if let Ok(secs) = body[..comma].trim().parse::<u64>() {
                        if secs > 0 {
                            extinf_duration = Some(secs as f64);
                        }
                    }
                    let title = body[comma + 1..].trim();
                    if !title.is_empty() {
                        extinf_title = Some(title.to_string());
                    }
                }
            }
            continue;
        }
        line = Some(l);
        break;
    }
    let line = line?;
    if line.starts_with("http://") || line.starts_with("https://") {
        // http(s) URL 目标：收录为 URL 轨道（target 为 None），
        // 播放侧由前端走「下载缓存再 play」链路（引擎只吃本地路径）。
        let ext = line
            .split('?')
            .next()
            .and_then(|p| p.rsplit('.').next())
            .map(|e| e.to_lowercase());
        let valid = ext.map(|e| AUDIO_EXTENSIONS.contains(&e.as_str())).unwrap_or(false);
        if valid || extinf_duration.is_some() {
            return Some(ResolvedStrm {
                target: None,
                url: Some(line.to_string()),
                extinf_title,
                extinf_duration,
            });
        }
        warn!("STRM 指向不可识别扩展名的 URL，跳过: {line}");
        return None;
    }
    let raw = Path::new(line);
    let target = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        strm_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join(raw)
    };
    let normalized = normalize_path(&target);
    // 目标必须是存在的音频文件（防套娃 strm / 脏内容被收录）
    let ext = normalized
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase());
    match ext {
        Some(e) if AUDIO_EXTENSIONS.contains(&e.as_str()) && normalized.is_file() => {
            Some(ResolvedStrm {
                target: Some(normalized),
                url: None,
                extinf_title,
                extinf_duration,
            })
        }
        _ => None,
    }
}

/// 规范化路径：解析 "." 与 ".." 组件，去除冗余分隔符。
fn normalize_path(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in p.components() {
        match comp {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn scan_file(path: &Path) -> Result<Option<Track>, String> {
    let meta = fs::metadata(path).map_err(|e| format!("读取文件信息失败: {e}"))?;
    let file_size = meta.len() as i64;
    let file_modified = meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);

    let format = path.extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_lowercase());

    // 用 audio-core 读取元数据；失败时不跳过文件，而是回退到文件名推断，
    // 保证扫描结果不丢歌（损坏/非常规编码的文件也能入库）
    let metadata = match audio_core::decoder::read_metadata(path) {
        Ok(m) => Some(m),
        Err(e) => {
            warn!("audio_core 无法读取元数据 {}: {e}，改用文件名推断", path.display());
            None
        }
    };

    // 用 audio-core 读取封面
    let cover_base64 = audio_core::decoder::read_cover(path)
        .ok()
        .and_then(|data| resize_and_encode(&data));

    let file_stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("?");
    let inferred = infer_from_filename(file_stem);

    let track = Track {
        id: 0,
        path: path.to_string_lossy().into_owned(),
        title: metadata.as_ref()
            .and_then(|m| m.title.as_deref().map(fix_gbk_tag))
            .or_else(|| {
                inferred.title.clone().or(Some(file_stem.to_string()))
            }),
        artist: metadata.as_ref()
            .and_then(|m| m.artist.as_deref().map(fix_gbk_tag))
            .or_else(|| {
                if inferred.artist.is_some() { inferred.artist.clone() } else { Some("未知艺术家".into()) }
            }),
        album: metadata.as_ref()
            .and_then(|m| m.album.as_deref().map(fix_gbk_tag))
            .or_else(|| Some("未知专辑".into())),
        album_artist: None,
        track_number: metadata.as_ref().and_then(|m| m.track_number.map(|n| n as i32)).or(inferred.track_number),
        disc_number: metadata.as_ref().and_then(|m| m.disc_number.map(|n| n as i32)),
        year: metadata.as_ref().and_then(|m| m.year),
        genre: metadata.as_ref().and_then(|m| m.genre.as_deref().map(fix_gbk_tag)),
        duration: metadata.as_ref()
            .map(|m| m.duration_secs)
            .filter(|d| *d > 0.1),
        sample_rate: metadata.as_ref().and_then(|m| m.sample_rate.map(|r| r as i32)),
        channels: metadata.as_ref().and_then(|m| m.channels.map(|c| c as i32)),
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

/// 从音频文件读取封面（data URI 格式），委托给 audio-core
pub fn get_file_cover(path: &Path) -> Result<Option<String>, String> {
    match audio_core::decoder::read_cover(path) {
        Ok(data) => Ok(resize_and_encode(&data)),
        Err(_) => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_file_cover_id3v2() {
        // 构造一个最小 ID3v2 文件：ID3v2.3 头 + APIC 帧（1×1 红色像素 PNG）
        // 委托给 audio_core::read_cover（内部使用 lofty）
        // PNG 用 image crate 现场编码生成（手写字节容易 CRC 不合法）
        let mut png_data: Vec<u8> = Vec::new();
        {
            use image::ImageEncoder as _;
            let encoder = image::codecs::png::PngEncoder::new(std::io::Cursor::new(&mut png_data));
            encoder
                .write_image(&[0xFFu8, 0x00, 0x00], 1, 1, image::ExtendedColorType::Rgb8)
                .unwrap();
        }

        // APIC 帧体: encoding(1) + MIME("image/png" + null) + pic_type(3) + desc(null) + img_data
        let mut apic_body = Vec::new();
        apic_body.push(0x03); // UTF-8 encoding
        apic_body.extend_from_slice(b"image/png\x00");
        apic_body.push(3); // front cover
        apic_body.push(0); // empty description (null)
        apic_body.extend_from_slice(&png_data);

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

        // 追加几帧真实的 MPEG1 Layer III 音频帧（lofty 需要音频帧才能识别文件类型）：
        // 128kbps / 44.1kHz / 无 padding，帧长 = 144 * 128000 / 44100 = 417 字节
        for _ in 0..4 {
            let mut mpeg_frame = vec![0u8; 417];
            mpeg_frame[0] = 0xFF;
            mpeg_frame[1] = 0xFB; // MPEG1 Layer III, 无 CRC
            mpeg_frame[2] = 0x90; // 128kbps, 44100Hz, 无 padding
            mpeg_frame[3] = 0x00;
            file.extend_from_slice(&mpeg_frame);
        }

        // 写入临时文件（用系统临时目录，Windows 没有 /tmp）
        let tmp = std::env::temp_dir().join("test_cover_synthetic.mp3");
        std::fs::write(&tmp, &file).unwrap();

        let result = get_file_cover(&tmp);
        assert!(result.is_ok(), "get_file_cover failed: {:?}", result);
        let cover = result.unwrap();
        assert!(cover.is_some(), "should have found a cover");
        // 封面经解码缩放后统一编码为 JPEG
        assert!(cover.unwrap().starts_with("data:image/jpeg;base64,"));

        let _ = std::fs::remove_file(tmp);
    }

    #[test]
    fn test_get_file_cover_no_id3() {
        // 没有 ID3v2 头的文件 → Ok(None)
        let tmp = std::env::temp_dir().join("test_cover_no_id3.mp3");
        std::fs::write(&tmp, &[0xFF, 0xFB, 0x90, 0x00]).unwrap(); // MPEG sync
        let result = get_file_cover(&tmp);
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
        let _ = std::fs::remove_file(tmp);
    }

    #[test]
    fn test_resolve_strm_target() {
        let dir = std::env::temp_dir().join("strm_test");
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        // 真实音频目标（相对同目录 / ../ 上溯 / 绝对路径三种写法）
        std::fs::write(dir.join("real.flac"), b"fLaC").unwrap();
        // 1. 同目录相对路径
        std::fs::write(dir.join("a.strm"), "real.flac\n").unwrap();
        let r = resolve_strm_target(&dir.join("a.strm"));
        assert_eq!(r.as_ref().map(|s| s.target.clone()), Some(Some(dir.join("real.flac"))));
        assert!(r.unwrap().extinf_title.is_none());
        // 2. ../ 上溯 + BOM
        std::fs::write(dir.join("sub/b.strm"), "\u{feff}../real.flac").unwrap();
        let r = resolve_strm_target(&dir.join("sub/b.strm"));
        assert_eq!(r.as_ref().map(|s| s.target.clone()), Some(Some(dir.join("real.flac"))));
        // 3. 绝对路径 + 前导空白行/注释
        std::fs::write(
            dir.join("c.strm"),
            format!("# comment\n\n  {}  \n", dir.join("real.flac").display()),
        )
        .unwrap();
        let r = resolve_strm_target(&dir.join("c.strm"));
        assert_eq!(r.as_ref().map(|s| s.target.clone()), Some(Some(dir.join("real.flac"))));
        // 3b. #EXTINF 信息行：标题 + 时长（Kodi 风格 strm 库）
        std::fs::write(
            dir.join("h.strm"),
            "#EXTINF:245,周杰伦 - 晴天\nreal.flac\n",
        )
        .unwrap();
        let r = resolve_strm_target(&dir.join("h.strm"));
        let rs = r.expect("h.strm 应解析成功");
        assert_eq!(rs.target, Some(dir.join("real.flac")));
        assert_eq!(rs.extinf_title.as_deref(), Some("周杰伦 - 晴天"));
        assert_eq!(rs.extinf_duration, Some(245.0));
        // 3c. #EXTINF 无标题/时长非法：忽略信息行不阻断目标解析
        std::fs::write(dir.join("i.strm"), "#EXTINF:0,\nreal.flac\n").unwrap();
        let r = resolve_strm_target(&dir.join("i.strm"));
        assert_eq!(r.as_ref().map(|s| s.target.clone()), Some(Some(dir.join("real.flac"))));
        assert!(r.unwrap().extinf_title.is_none());
        // 4. http(s) URL 目标 → 收录为 URL 轨道（target 为 None，url 有效）
        std::fs::write(dir.join("d.strm"), "http://nas/music/x.flac\n").unwrap();
        let r = resolve_strm_target(&dir.join("d.strm"));
        assert!(r.is_some(), "http(s) URL 目标应解析成功");
        let rd = r.unwrap();
        assert_eq!(rd.target, None);
        assert_eq!(rd.url.as_deref(), Some("http://nas/music/x.flac"));
        // 5. 目标不存在 → None
        std::fs::write(dir.join("e.strm"), "missing.flac\n").unwrap();
        assert!(resolve_strm_target(&dir.join("e.strm")).is_none());
        // 6. 套娃 strm（目标也是 strm）→ None（非音频目标不收）
        std::fs::write(dir.join("f.strm"), "a.strm\n").unwrap();
        assert!(resolve_strm_target(&dir.join("f.strm")).is_none());
        // 7. 空内容 / 只有注释 → None
        std::fs::write(dir.join("g.strm"), "# only comment\n").unwrap();
        assert!(resolve_strm_target(&dir.join("g.strm")).is_none());
        let _ = std::fs::remove_dir_all(dir);
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


