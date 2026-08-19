use std::path::Path;

/// 音频分析结果（BPM + 调性 + 能量，置信度 0~1）
pub struct AnalyzeResult {
    pub bpm: Option<f32>,
    pub key: Option<String>,
    pub energy: Option<f32>,
    /// BPM 置信度（0~1）
    pub bpm_confidence: Option<f32>,
    /// 调性置信度（0~1）
    pub key_confidence: Option<f32>,
}

/// 分析音频文件（BPM + 调性 + 能量）。与 mobile `analyze.rs` 同源。
pub fn analyze_file(path: String) -> Result<AnalyzeResult, String> {
    let result = audio_core::analysis::analyze_file(Path::new(&path))
        .map_err(|e| format!("音频分析失败: {e}"))?;

    Ok(AnalyzeResult {
        bpm: result.bpm,
        key: result.key,
        energy: result.energy,
        bpm_confidence: result.bpm_confidence,
        key_confidence: result.key_confidence,
    })
}

/// 分析 PCM 样本数据（供未来实时分析等场景复用）
pub fn analyze_pcm_samples(
    samples: Vec<f32>,
    sample_rate: u32,
    channels: u32,
) -> AnalyzeResult {
    let result =
        audio_core::analysis::analyze_from_samples(&samples, sample_rate, channels);

    AnalyzeResult {
        bpm: result.bpm,
        key: result.key,
        energy: result.energy,
        bpm_confidence: result.bpm_confidence,
        key_confidence: result.key_confidence,
    }
}