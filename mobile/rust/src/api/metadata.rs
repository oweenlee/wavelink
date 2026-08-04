use std::path::Path;

/// ReplayGain 响度归一化增益值
pub struct ReplayGainResult {
    /// 音轨增益 (dB)，如 -5.23
    pub track_gain_db: Option<f32>,
    /// 专辑增益 (dB)，如 -7.14
    pub album_gain_db: Option<f32>,
    /// 音轨真峰值
    pub track_peak: Option<f32>,
    /// 专辑真峰值
    pub album_peak: Option<f32>,
}

/// 从音频文件读取 ReplayGain 标签
pub fn read_replaygain(path: String) -> Result<ReplayGainResult, String> {
    let rg = audio_core::decoder::read_replaygain(std::path::Path::new(&path))?;
    Ok(ReplayGainResult {
        track_gain_db: rg.track_gain_db,
        album_gain_db: rg.album_gain_db,
        track_peak: rg.track_peak,
        album_peak: rg.album_peak,
    })
}

/// 读取音频文件封面图（JPEG/PNG 原始字节），用 lofty 提取
pub fn get_cover_bytes(path: String) -> Result<Vec<u8>, String> {
    let p = Path::new(&path);
    // 先用 audio-core 的 symphonia 方式提取
    if let Ok(data) = audio_core::decoder::read_cover(p) {
        return Ok(data);
    }
    // symphonia 没读到，用 lofty 兜底
    extract_cover_lofty(p)
}

/// 用 lofty 提取封面
fn extract_cover_lofty(path: &Path) -> Result<Vec<u8>, String> {
    use lofty::file::TaggedFileExt;

    let tagged_file = lofty::read_from_path(path)
        .map_err(|e| format!("lofty 读取失败: {e}"))?;

    // 遍历所有标签，取第一张有效封面
    for tag in tagged_file.tags() {
        for pic in tag.pictures() {
            let pic_type = pic.pic_type();
            if matches!(pic_type, lofty::picture::PictureType::CoverFront | lofty::picture::PictureType::Media) {
                let data = pic.data();
                if !data.is_empty() {
                    return Ok(data.to_vec());
                }
            }
        }
    }
    // 没有 CoverFront，取任意图片
    for tag in tagged_file.tags() {
        for pic in tag.pictures() {
            let data = pic.data();
            if !data.is_empty() {
                return Ok(data.to_vec());
            }
        }
    }
    Err("未找到封面".into())
}

/// 音频文件元数据
pub struct MetadataResult {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_secs: f64,
    pub has_cover: bool,
    pub cover_bytes: Vec<u8>,
}

/// 读取音频文件元数据（标题/艺术家/专辑/封面/时长），同时提取封面字节
/// 避免 Dart 层再调 getCoverBytes 二次解析文件
pub fn read_metadata(path: String) -> Result<MetadataResult, String> {
    let meta = audio_core::decoder::read_metadata(Path::new(&path))?;

    let mut cover_bytes = Vec::new();
    let mut has_cover = meta.has_cover;

    if has_cover {
        if let Ok(data) = audio_core::decoder::read_cover(Path::new(&path)) {
            cover_bytes = data;
        } else if let Ok(data) = extract_cover_lofty(Path::new(&path)) {
            cover_bytes = data;
        }
    } else if let Ok(data) = extract_cover_lofty(Path::new(&path)) {
        cover_bytes = data;
        has_cover = true;
    }

    Ok(MetadataResult {
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        duration_secs: meta.duration_secs,
        has_cover,
        cover_bytes,
    })
}
