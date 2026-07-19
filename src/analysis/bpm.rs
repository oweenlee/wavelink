/// 用自相关法检测 BPM
///
/// 流程：
/// 1. 帧能量 onset 包络（半波整流差分）
/// 2. 自相关，在 60-200 BPM 范围找峰
pub fn detect_bpm(samples: &[f32], sample_rate: u32) -> Option<f32> {
    let frame_size = 1024usize;
    let hop_size = 512usize;

    if samples.len() < frame_size {
        return None;
    }

    // 计算 onset 包络
    let mut onset = Vec::new();
    let mut prev_rms = 0.0f32;
    let mut chunk_start = 0;
    while chunk_start + frame_size / 4 <= samples.len() {
        let end = (chunk_start + hop_size).min(samples.len());
        let chunk = &samples[chunk_start..end];
        let rms = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt();
        let diff = rms - prev_rms;
        onset.push(if diff > 0.0 { diff } else { 0.0 });
        prev_rms = rms;
        chunk_start += hop_size;
    }

    if onset.len() < 20 {
        return None;
    }

    let n = onset.len();
    let mean = onset.iter().sum::<f32>() / n as f32;
    let centered: Vec<f32> = onset.iter().map(|x| x - mean).collect();

    let frame_rate = sample_rate as f32 / hop_size as f32;
    let min_bpm = 60.0;
    let max_bpm = 200.0;
    let min_lag = (frame_rate * 60.0 / max_bpm).round() as usize;
    let max_lag = (frame_rate * 60.0 / min_bpm).round() as usize;
    let max_lag = max_lag.min(n / 2);

    if min_lag >= max_lag {
        return None;
    }

    // 加权自相关，利用中心削波抑制弱拍
    let threshold = centered.iter().map(|x| x.abs()).sum::<f32>() / n as f32 * 0.5;
    let clipped: Vec<f32> = centered
        .iter()
        .map(|&x| if x > threshold { x - threshold } else { 0.0 })
        .collect();

    let mut best_corr = 0.0f32;
    let mut best_lag = min_lag;
    for lag in min_lag..=max_lag {
        let mut corr = 0.0f32;
        for i in 0..(n - lag) {
            corr += clipped[i] * clipped[i + lag];
        }
        corr /= (n - lag) as f32;
        if corr > best_corr {
            best_corr = corr;
            best_lag = lag;
        }
    }

    if best_corr < 1e-6 {
        return None;
    }

    let bpm = frame_rate * 60.0 / best_lag as f32;
    Some((bpm * 10.0).round() / 10.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_bpm_with_impulse_train() {
        // 合成 120 BPM 脉冲序列（每 0.5 秒一个脉冲）
        let sample_rate = 44100;
        let dur_secs = 10;
        let len = sample_rate * dur_secs;
        let mut samples = vec![0.0f32; len as usize];
        let interval = (sample_rate as f64 * 60.0 / 120.0) as usize;
        let mut pos = 0;
        while pos < len as usize {
            for i in 0..64 {
                if pos + i < len as usize {
                    samples[pos + i] = 0.5 - (i as f32 / 64.0 * std::f32::consts::PI).cos() * 0.5;
                }
            }
            pos += interval;
        }
        let bpm = detect_bpm(&samples, sample_rate);
        assert!(bpm.is_some(), "应有 BPM 检测结果");
        let val = bpm.unwrap();
        assert!(
            (val - 120.0).abs() < 2.0,
            "BPM 应接近 120，实际 {val}"
        );
    }

    #[test]
    fn test_detect_bpm_silence() {
        let samples = vec![0.0f32; 44100 * 5];
        let bpm = detect_bpm(&samples, 44100);
        assert!(bpm.is_none(), "静音应无 BPM");
    }
}
