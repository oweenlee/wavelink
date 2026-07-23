use std::path::Path;

/// CUE 音轨
pub struct CueTrackResult {
    pub num: String,
    pub title: Option<String>,
    pub performer: Option<String>,
    pub start_secs: f64,
    pub pregap_secs: f64,
}

/// CUE 文件条目（对应一个物理音频文件）
pub struct CueFileResult {
    pub path: String,
    pub tracks: Vec<CueTrackResult>,
}

/// CUE 分轨解析结果
pub struct CueSheetResult {
    pub title: Option<String>,
    pub performer: Option<String>,
    pub files: Vec<CueFileResult>,
}

/// 解析 .cue 文件，返回分轨表
pub fn parse_cue_file(path: String) -> Result<CueSheetResult, String> {
    let sheet = audio_core::cue::parse_cue(Path::new(&path))?;
    Ok(CueSheetResult {
        title: sheet.title,
        performer: sheet.performer,
        files: sheet
            .files
            .into_iter()
            .map(|f| CueFileResult {
                path: f.path,
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
            })
            .collect(),
    })
}
