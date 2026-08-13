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
    /// 内嵌歌词（LRC 文本：ID3 USLT / Vorbis LYRICS / MP4 ©lyr）
    pub lyrics: Option<String>,
}

/// 无封面诊断：输出 MP3 ID3v2 标签结构摘要，辅助定位"有封面却解析不出"
/// 的根因（标签被截断 / 标签不在文件头 / 真无标签 / 非 MP3）。
fn mp3_tag_summary(path: &Path) -> String {
    use std::io::Read;
    let mut f = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => return format!("open fail: {e}"),
    };
    let file_len = match f.metadata() {
        Ok(m) => m.len(),
        Err(_) => 0,
    };
    let mut head = [0u8; 10];
    if f.read_exact(&mut head).is_err() {
        return format!("file too small ({file_len}B)");
    }
    if &head[0..3] == b"ID3" {
        let size = ((head[6] as u32) << 21)
            | ((head[7] as u32) << 14)
            | ((head[8] as u32) << 7)
            | (head[9] as u32);
        format!(
            "ID3v2.{}.{} tag_size={}B (file={}B{})",
            head[3],
            head[4],
            size + 10,
            file_len,
            if (size as u64 + 10) > file_len {
                ", TAG TRUNCATED (窗口不够或标签不完整)"
            } else {
                ""
            }
        )
    } else {
        format!(
            "no ID3v2 at offset 0 (file={file_len}B, magic={:02x?})",
            &head[..3]
        )
    }
}

/// 读取音频文件元数据（标题/艺术家/专辑/封面/时长），同时提取封面字节
/// 避免 Dart 层再调 getCoverBytes 二次解析文件
pub fn read_metadata(path: String) -> Result<MetadataResult, String> {
    let meta = match audio_core::decoder::read_metadata(Path::new(&path)) {
        Ok(m) => m,
        Err(e) => {
            // 封面提取流程：symphonia 探测失败也输出结构诊断（截断文件常见）
            if path.contains(".smb_head") {
                eprintln!(
                    "[meta] 封面提取解析失败 {path}: {e}; {}",
                    mp3_tag_summary(Path::new(&path))
                );
            }
            return Err(e.to_string());
        }
    };

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

    // 诊断：封面提取流程（.smb_head 临时文件）读到数据但无封面时，
    // 输出标签结构摘要，定位"有封面却解析不出"的根因（用户反馈场景）
    if !has_cover && path.contains(".smb_head") {
        eprintln!(
            "[meta] 封面提取无封面诊断 {}: {}",
            path,
            mp3_tag_summary(Path::new(&path))
        );
    }

    Ok(MetadataResult {
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        duration_secs: meta.duration_secs,
        has_cover,
        cover_bytes,
        lyrics: meta.lyrics,
    })
}
