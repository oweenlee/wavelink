//! 元数据读取与格式探测（标签 / 封面 / ReplayGain / 时长 / 采样率 / 位深 / DSD 信息）
//!
//! 与流式解码（[`super::Decoder`]）分离：本文件所有函数只读文件头/标签，不完整解码。

use std::fs::File;
use std::path::Path;

use lofty::prelude::*;
use lofty::read_from_path;
use lofty::tag::ItemKey;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;


/// 音频文件元数据
pub struct Metadata {
    /// 曲名
    pub title: Option<String>,
    /// 艺术家
    pub artist: Option<String>,
    /// 专辑名
    pub album: Option<String>,
    /// 流派
    pub genre: Option<String>,
    /// 发行年份
    pub year: Option<i32>,
    /// 音轨号
    pub track_number: Option<u32>,
    /// 光盘号
    pub disc_number: Option<u32>,
    /// 时长（秒）
    pub duration_secs: f64,
    /// 是否含有内嵌封面
    pub has_cover: bool,
    /// 内嵌歌词（LRC 文本：ID3 USLT / Vorbis LYRICS / MP4 ©lyr）
    pub lyrics: Option<String>,
    /// 采样率（Hz）
    pub sample_rate: Option<u32>,
    /// 声道数
    pub channels: Option<u32>,
}

/// 提取内嵌歌词文本（LRC 格式）：ID3v2 USLT / FLAC·OGG LYRICS / MP4 ©lyr。
/// 歌词可能存于 Lyrics（纯歌词）或 UnsyncLyrics（LRC 文本）两种键。
fn extract_lyrics(tag: &lofty::tag::Tag) -> Option<String> {
    tag.get_string(ItemKey::Lyrics)
        .or_else(|| tag.get_string(ItemKey::UnsyncLyrics))
        .map(|s| s.to_string())
        .filter(|s| !s.trim().is_empty())
}

/// 读取音频文件元数据（标题/艺术家/专辑/流派/年份/音轨号/光盘号/封面/时长）
pub fn read_metadata(path: &Path) -> Result<Metadata, String> {
    // 优先用 lofty 读取完整标签
    if let Ok(tagged_file) = read_from_path(path) {
        let duration_secs = tagged_file.properties().duration().as_secs_f64();

        let mut meta = Metadata {
            title: None, artist: None, album: None,
            genre: None, year: None,
            track_number: None, disc_number: None,
            duration_secs, has_cover: false, lyrics: None,
            sample_rate: None, channels: None,
        };

        if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
            meta.title = tag.title().map(|s| s.to_string());
            meta.artist = tag.artist().map(|s| s.to_string());
            meta.album = tag.album().map(|s| s.to_string());
            meta.genre = tag.genre().map(|s| s.to_string());
            meta.year = tag.date().map(|d| d.year as i32);
            meta.track_number = tag.track();
            meta.disc_number = tag.disk();
            meta.has_cover = !tag.pictures().is_empty();
            meta.lyrics = extract_lyrics(tag);
        }

        meta.sample_rate = tagged_file.properties().sample_rate();
        meta.channels = tagged_file.properties().channels().map(|c| c as u32);

        return Ok(meta);
    }

    // lofty 不支持的格式（DSF/DFF）回退到 Symphonia 探测时长
    let duration_secs = probe_duration_secs(path).unwrap_or(0.0);

    Ok(Metadata {
        title: None, artist: None, album: None,
        genre: None, year: None,
        track_number: None, disc_number: None,
        duration_secs, has_cover: false, lyrics: None,
        sample_rate: None, channels: None,
    })
}

/// 用 Symphonia 打开文件并探测容器格式（probe_duration/sample_rate/bit_depth 共用）
fn open_symphonia_format(path: &Path) -> Option<Box<dyn symphonia::core::formats::FormatReader>> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .ok()
}

/// 用 Symphonia 探测音频时长（秒），不完整解码
pub fn probe_duration_secs(path: &Path) -> Option<f64> {
    // DSF：Symphonia 无 DSD 格式支持，走头部直解
    if is_dsf_file(path) {
        if let Some(secs) = probe_dsf_secs(path) {
            return Some(secs);
        }
    }
    let format = open_symphonia_format(path)?;
    format.tracks().iter()
        .find(|t| matches!(&t.codec_params, Some(symphonia::core::codecs::CodecParameters::Audio(p))
            if p.codec != symphonia::core::codecs::audio::CODEC_ID_NULL_AUDIO))
        .and_then(|t| {
            let frames = t.num_frames?;
            let tb = t.time_base?;
            let secs = frames as f64 * tb.numer.get() as f64 / tb.denom.get() as f64;
            if secs > 0.0 { Some(secs) } else { None }
        })
}

/// 读取封面图片（JPEG/PNG/WEBP 原始字节）。
/// 支持音频格式（lofty）以及 MKV/WebM 附件封面。
pub fn read_cover(path: &Path) -> Result<Vec<u8>, String> {
    // 先用 lofty 读音频 + MP4 封面
    if let Ok(tagged_file) = read_from_path(path) {
        if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
            if let Some(pic) = tag.pictures().first() {
                let data = pic.data();
                if !data.is_empty() {
                    return Ok(data.to_vec());
                }
            }
        }
    }

    // MKV/WebM 回退：从附件中找封面
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        if ext.eq_ignore_ascii_case("mkv") || ext.eq_ignore_ascii_case("webm") || ext.eq_ignore_ascii_case("mka") {
            if let Ok(mkv) = matroska::open(path) {
                for att in &mkv.attachments {
                    let name = att.name.to_lowercase();
                    if (name.starts_with("cover") || name.contains("cover"))
                        && !att.data.is_empty()
                            && (att.mime_type == "image/jpeg"
                                || att.mime_type == "image/png"
                                || att.mime_type == "image/webp")
                        {
                            return Ok(att.data.clone());
                        }
                }
                // 没有命名规范匹配的，按魔数返回第一个图片附件
                for att in &mkv.attachments {
                    let d = &att.data;
                    if d.len() >= 4
                        && ((d[0] == 0xFF && d[1] == 0xD8)      // JPEG
                            || d[0..4] == [0x89, 0x50, 0x4E, 0x47] // PNG
                            || (d.len() >= 12 && d[0..4] == [0x52, 0x49, 0x46, 0x46] && d[8..12] == [0x57, 0x45, 0x42, 0x50])) // RIFF+WEBP
                    {
                        return Ok(d.clone());
                    }
                }
            }
        }
    }

    Err("未找到封面".into())
}

/// ReplayGain 响度归一化增益值
#[derive(serde::Serialize)]
pub struct ReplayGain {
    /// 音轨增益 (dB)，如 -5.23
    pub track_gain_db: Option<f32>,
    /// 专辑增益 (dB)，如 -7.14
    pub album_gain_db: Option<f32>,
    /// 音轨真峰值，如 0.999969
    pub track_peak: Option<f32>,
    /// 专辑真峰值
    pub album_peak: Option<f32>,
}

/// 从音频文件读取 ReplayGain 标签（REPLAYGAIN_TRACK/ALBUM_GAIN/PEAK）
pub fn read_replaygain(path: &Path) -> Result<ReplayGain, String> {
    let tagged_file = read_from_path(path)
        .map_err(|e| format!("无法读取 ReplayGain: {e}"))?;

    let mut rg = ReplayGain { track_gain_db: None, album_gain_db: None, track_peak: None, album_peak: None };

    if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
        // 从 ItemKey 获取 ReplayGain 值（lofty 自动映射 ID3v2 TXXX / Vorbis / MP4）
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainTrackGain) {
            rg.track_gain_db = parse_replaygain_str(val);
        }
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumGain) {
            rg.album_gain_db = parse_replaygain_str(val);
        }
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainTrackPeak) {
            rg.track_peak = val.trim().parse::<f32>().ok();
        }
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumPeak) {
            rg.album_peak = val.trim().parse::<f32>().ok();
        }
    }

    Ok(rg)
}

/// 解析 "-5.23 dB" 格式的 ReplayGain 增益字符串
fn parse_replaygain_str(s: &str) -> Option<f32> {
    let s = s.trim();
    // 去掉 " dB" 后缀
    let num = if let Some(stripped) = s.strip_suffix(" dB").or_else(|| s.strip_suffix("db")) {
        stripped
    } else {
        s
    };
    num.parse::<f32>().ok()
}

/// 快速探测音频文件的采样率（不完整解码，只读文件头）
pub fn probe_sample_rate(path: &Path) -> Option<u32> {
    let format = open_symphonia_format(path)?;
    for track in format.tracks() {
        if let Some(symphonia::core::codecs::CodecParameters::Audio(audio)) = &track.codec_params {
            let rate = audio.sample_rate.unwrap_or(44100);
            if rate > 0 { return Some(rate); }
        }
    }
    None
}

/// DSF 头部时长：fmt chunk 内 sampling freq(4B @56) / sample count(8B @64)，均小端。
/// 布局见 Sony DSF 规范（"DSD " 头 28B + "fmt " 12B 后为字段区）。
pub fn probe_dsf_secs(path: &Path) -> Option<f64> {
    let mut f = File::open(path).ok()?;
    let mut buf = [0u8; 76];
    use std::io::Read;
    f.read_exact(&mut buf).ok()?;
    if &buf[0..4] != b"DSD " {
        return None;
    }
    let rate = u32::from_le_bytes(buf[56..60].try_into().ok()?) as f64;
    let count = u64::from_le_bytes(buf[64..72].try_into().ok()?);
    if rate <= 0.0 {
        return None;
    }
    Some(count as f64 / rate)
}

/// 快速探测音频文件的位深（不完整解码，只读文件头）
pub fn probe_bit_depth(path: &Path) -> Option<u16> {
    let format = open_symphonia_format(path)?;
    for track in format.tracks() {
        if let Some(symphonia::core::codecs::CodecParameters::Audio(audio)) = &track.codec_params {
            let bits = audio.bits_per_sample.unwrap_or(16);
            if bits > 0 { return Some(bits as u16); }
        }
    }
    None
}

// ── DSD 信息探测 ──────────────────────────────────────────────────────────

/// 判断扩展名是否为 DSD 容器（DSF/DFF）
pub fn is_dsd_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some(ext) if ext.eq_ignore_ascii_case("dsf") || ext.eq_ignore_ascii_case("dff")
    )
}

/// 判断扩展名是否为 DSF（DFF 无简单头部时长字段，走 symphonia 也探测不到，返回 None）
pub fn is_dsf_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some(ext) if ext.eq_ignore_ascii_case("dsf")
    )
}

/// 探测 DSD 文件的原始速率和声道数（只读文件头）。
/// 返回 `(dsd_rate_hz, channels)`，如 DSD64 立体声 → `(2822400, 2)`。
/// 非 DSD 文件或打开失败返回 None。
pub fn probe_dsd_info(path: &Path) -> Option<(u32, u32)> {
    use dsd_reader::DsdReader;
    let reader = DsdReader::from_container(path.to_path_buf()).ok()?;
    let mult = reader.dsd_rate();
    if mult <= 0 {
        return None;
    }
    Some((2_822_400 * mult as u32, reader.channels_num() as u32))
}
