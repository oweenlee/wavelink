//! 桌面端音频元数据 FFI（镜像 mobile `api::metadata`）
//!
//! 扫描期从音频文件读取真实标签（标题/艺术家/专辑/时长/内嵌歌词），
//! 替代「文件名 Artist - Title 约定」猜测。主提取走 audio-core 的
//! symphonia 读取器，lofty 作封面兜底（与 mobile 同策略）。

use std::path::Path;

use flutter_rust_bridge::frb;

/// 音频文件元数据（扫描期一次性读取，含封面字节避免 Dart 二次解析文件）
pub struct MetadataResult {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    /// 音轨号（专辑内排序参考，桌面端暂仅展示/调试用）
    pub track_number: Option<u32>,
    pub duration_secs: f64,
    pub has_cover: bool,
    pub cover_bytes: Vec<u8>,
    /// 内嵌歌词（LRC 文本：ID3 USLT / Vorbis LYRICS / MP4 ©lyr）
    pub lyrics: Option<String>,
}

/// 读取音频文件元数据（标题/艺术家/专辑/时长/内嵌歌词），同时提取封面字节
/// 避免 Dart 层再调 get_cover_bytes 二次解析文件（镜像 mobile `read_metadata`）。
#[frb]
pub fn read_metadata(path: String) -> Result<MetadataResult, String> {
    let p = Path::new(&path);
    let meta = audio_core::decoder::read_metadata(p)?;

    let mut cover_bytes = Vec::new();
    let mut has_cover = meta.has_cover;

    if has_cover {
        if let Ok(data) = audio_core::decoder::read_cover(p) {
            cover_bytes = data;
        } else if let Ok(data) = extract_cover_lofty(p) {
            cover_bytes = data;
        }
    } else if let Ok(data) = extract_cover_lofty(p) {
        cover_bytes = data;
        has_cover = true;
    }

    Ok(MetadataResult {
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        track_number: meta.track_number,
        duration_secs: meta.duration_secs,
        has_cover,
        cover_bytes,
        lyrics: meta.lyrics,
    })
}

/// 用 lofty 遍历所有标签图片兜底提取封面（read_cover 漏掉的非首图/次标签场景）。
fn extract_cover_lofty(path: &Path) -> Result<Vec<u8>, String> {
    use lofty::file::TaggedFileExt;

    let tagged_file = lofty::read_from_path(path)
        .map_err(|e| format!("lofty 读取失败: {e}"))?;

    // 先取封面/媒体类图片（优先 CoverFront / Media）
    for tag in tagged_file.tags() {
        for pic in tag.pictures() {
            let pic_type = pic.pic_type();
            if matches!(
                pic_type,
                lofty::picture::PictureType::CoverFront
                    | lofty::picture::PictureType::Media
            ) {
                let data = pic.data();
                if !data.is_empty() {
                    return Ok(data.to_vec());
                }
            }
        }
    }
    // 没有封面类图片，取任意图片
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
