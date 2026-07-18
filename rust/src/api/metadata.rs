use std::path::Path;

/// 音频文件元数据
pub struct MetadataResult {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_secs: f64,
    pub has_cover: bool,
}

/// 读取音频文件元数据（标题/艺术家/专辑/封面/时长）
pub fn read_metadata(path: String) -> Result<MetadataResult, String> {
    let meta = audio_core::decoder::read_metadata(Path::new(&path))?;

    Ok(MetadataResult {
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        duration_secs: meta.duration_secs,
        has_cover: meta.has_cover,
    })
}
