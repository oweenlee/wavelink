//! 音频分析：BPM 检测、调性识别、能量值
//!
//! 使用自相关法检测 BPM，Chromagram + Krumhansl-Schmuckler 识别调性。

pub mod bpm;
pub mod key;

use std::path::Path;

use crate::decoder;
use crate::TARGET_CHANNELS;
use crate::TARGET_SAMPLE_RATE;

/// 音频分析结果（BPM / 调性 / 能量）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AnalysisResult {
    /// 每分钟拍数，None 表示未检测到稳定节拍
    pub bpm: Option<f32>,
    /// 调性（如 "C", "Gm"），None 表示无法识别
    pub key: Option<String>,
    /// 能量值（0~1 左右），基于 RMS 计算
    pub energy: Option<f32>,
}

/// 将交织立体声样本下混为单声道
pub fn mix_to_mono(samples: &[f32], channels: u32) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    let ch = channels as usize;
    let n = samples.len() / ch;
    let mut mono = Vec::with_capacity(n);
    for i in 0..n {
        let mut sum = 0.0f32;
        for c in 0..ch {
            sum += samples[i * ch + c];
        }
        mono.push(sum / ch as f32);
    }
    mono
}

/// 分析音频文件：解码前 N 秒 → BPM + 调性 + 能量
///
/// 只取开头 [ANALYSIS_MAX_SECS] 秒：BPM/调性对全曲采样不敏感，
/// 但解码+FFT 成本与时长成正比，截断可将播放页标签的等待时间
/// 从数秒压到亚秒级（3 分钟歌约 1/2，5 分钟歌约 1/3.3）。
pub const ANALYSIS_MAX_SECS: f64 = 90.0;

pub fn analyze_file(path: &Path) -> Result<AnalysisResult, String> {
    let samples = decoder::decode_to_memory_prefix(
        path,
        TARGET_SAMPLE_RATE,
        TARGET_CHANNELS,
        Some(ANALYSIS_MAX_SECS),
    )
    .map_err(|e| format!("解码失败: {e}"))?;

    Ok(analyze_from_samples(
        &samples,
        TARGET_SAMPLE_RATE,
        TARGET_CHANNELS,
    ))
}

/// 从 PCM 样本分析 BPM + 调性 + 能量
/// 从 PCM 样本数据中分析 BPM / 调性 / 能量
pub fn analyze_from_samples(samples: &[f32], sample_rate: u32, channels: u32) -> AnalysisResult {
    let mono = mix_to_mono(samples, channels);

    let bpm = bpm::detect_bpm(&mono, sample_rate);
    let (key, energy) = key::detect_key(&mono, sample_rate);

    AnalysisResult { bpm, key, energy }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mix_to_mono_stereo() {
        let stereo = vec![1.0, 3.0, 2.0, 4.0]; // 2 samples: (1,3), (2,4)
        let mono = mix_to_mono(&stereo, 2);
        assert_eq!(mono.len(), 2);
        assert!((mono[0] - 2.0).abs() < 1e-6);
        assert!((mono[1] - 3.0).abs() < 1e-6);
    }

    #[test]
    fn test_mix_to_mono_mono() {
        let m = vec![1.0, 2.0, 3.0];
        let mono = mix_to_mono(&m, 1);
        assert_eq!(mono, m);
    }

    #[test]
    fn test_analyze_empty() {
        let samples = vec![0.0f32; 44100 * 2];
        let result = analyze_from_samples(&samples, 44100, 2);
        assert!(result.bpm.is_none(), "静音应无 BPM");
        assert!(result.key.is_none(), "静音应无调性");
    }
}
