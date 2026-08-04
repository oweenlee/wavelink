/// 播放列表条目
pub struct PlaylistEntryResult {
    pub path: String,
    pub title: Option<String>,
    pub duration_secs: f64,
}

/// 解析播放列表文件（自动识别 M3U/M3U8/PLS），返回条目列表
pub fn parse_playlist_file(path: String) -> Result<Vec<PlaylistEntryResult>, String> {
    let entries = audio_core::playlist::parse_playlist(std::path::Path::new(&path))?;
    Ok(entries
        .into_iter()
        .map(|e| PlaylistEntryResult {
            path: e.path,
            title: e.title,
            duration_secs: e.duration_secs,
        })
        .collect())
}
