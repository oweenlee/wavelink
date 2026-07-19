use realfft::RealFftPlanner;

/// Krumhansl-Schmuckler 调性 profiles（对于 C 大调 / A 小调）
const KS_MAJOR: [f32; 12] = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const KS_MINOR: [f32; 12] = [
    6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
];
const NOTE_NAMES: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];

fn circ_shift(arr: &[f32; 12], shift: usize) -> [f32; 12] {
    let mut out = [0.0f32; 12];
    for i in 0..12 {
        out[i] = arr[(i + shift) % 12];
    }
    out
}

fn pearson_correlation(a: &[f32; 12], b: &[f32; 12]) -> f32 {
    let n = 12f32;
    let sum_a: f32 = a.iter().sum();
    let sum_b: f32 = b.iter().sum();
    let sum_aa: f32 = a.iter().map(|x| x * x).sum();
    let sum_bb: f32 = b.iter().map(|x| x * x).sum();
    let sum_ab: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let num = n * sum_ab - sum_a * sum_b;
    let den = ((n * sum_aa - sum_a * sum_a) * (n * sum_bb - sum_b * sum_b)).sqrt();
    if den.abs() < 1e-10 {
        0.0
    } else {
        num / den
    }
}

/// 从频谱 bin 的能量累积到 12 个半音音级上
fn compute_chromagram(mono: &[f32], sample_rate: u32) -> Option<[f32; 12]> {
    let frame_size = 4096;
    let hop_size = 2048;

    if mono.len() < frame_size {
        return None;
    }

    // Hann window
    let mut window = vec![0.0f32; frame_size];
    for (i, w) in window.iter_mut().enumerate() {
        let angle = 2.0 * std::f32::consts::PI * i as f32 / (frame_size - 1) as f32;
        *w = 0.5 * (1.0 - angle.cos());
    }

    let mut planner = RealFftPlanner::new();
    let fft = planner.plan_fft_forward(frame_size);

    let mut chroma = [0.0f32; 12];
    let mut frames = 0usize;
    let freq_per_bin = sample_rate as f32 / frame_size as f32;

    for start in (0..mono.len().saturating_sub(frame_size)).step_by(hop_size) {
        let mut frame = Vec::with_capacity(frame_size);
        for i in 0..frame_size {
            frame.push(mono[start + i] * window[i]);
        }

        let mut spectrum = vec![realfft::num_complex::Complex::new(0.0f32, 0.0f32); frame_size / 2 + 1];
        fft.process(&mut frame, &mut spectrum).ok();
        for (bin, c) in spectrum.iter().enumerate().skip(1) {
            let freq = bin as f32 * freq_per_bin;
            // 只关注音乐音域
            if !(65.0..=2100.0).contains(&freq) {
                continue;
            }
            let mag_sq = c.norm_sqr();
            // 频率 → MIDI 编号
            let midi = 12.0 * (freq / 440.0).log2() + 69.0;
            let semitone = ((midi + 0.5).floor() as i32).rem_euclid(12) as usize;
            chroma[semitone] += mag_sq;
        }
        frames += 1;
    }

    if frames == 0 {
        return None;
    }

    // 归一化
    let sum: f32 = chroma.iter().sum();
    if sum > 1e-10 {
        for c in &mut chroma {
            *c /= sum;
        }
        Some(chroma)
    } else {
        None
    }
}

/// 检测调性（major/minor + 根音）
/// 返回 (key_name, energy)
pub fn detect_key(mono: &[f32], sample_rate: u32) -> (Option<String>, Option<f32>) {
    let chroma = match compute_chromagram(mono, sample_rate) {
        Some(c) => c,
        None => return (None, None),
    };

    let mut best_corr = -2.0f32;
    let mut best_root = 0usize;
    let mut best_is_major = true;

    for root in 0..12 {
        let shifted_major = circ_shift(&KS_MAJOR, root);
        let corr_major = pearson_correlation(&chroma, &shifted_major);
        if corr_major > best_corr {
            best_corr = corr_major;
            best_root = root;
            best_is_major = true;
        }
        let shifted_minor = circ_shift(&KS_MINOR, root);
        let corr_minor = pearson_correlation(&chroma, &shifted_minor);
        if corr_minor > best_corr {
            best_corr = corr_minor;
            best_root = root;
            best_is_major = false;
        }
    }

    let key = format!(
        "{}{}",
        NOTE_NAMES[best_root],
        if best_is_major { "" } else { "m" }
    );

    // energy: 信号平均 RMS 的对数
    let energy = (mono.iter().map(|s| s * s).sum::<f32>() / mono.len() as f32 + 1e-10)
        .sqrt()
        .max(1e-10);
    let energy_db = 20.0 * energy.log10();
    let energy_norm = ((energy_db + 60.0) / 60.0).clamp(0.0, 1.0);

    (Some(key), Some(energy_norm))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chromagram_silence() {
        let mono = vec![0.0f32; 44100 * 2];
        let chroma = compute_chromagram(&mono, 44100);
        assert!(chroma.is_none(), "静音应无 Chromagram");
    }

    #[test]
    fn test_circ_shift() {
        let arr = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0];
        let shifted = circ_shift(&arr, 1);
        assert_eq!(shifted[0], 2.0);
        assert_eq!(shifted[1], 3.0);
        assert_eq!(shifted[10], 12.0);
        assert_eq!(shifted[11], 1.0);
    }

    #[test]
    fn test_correlation_identity() {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0];
        let corr = pearson_correlation(&a, &a);
        assert!((corr - 1.0).abs() < 1e-6, "自相关应为 1: {corr}");
    }

    #[test]
    fn test_correlation_negative() {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0];
        let b = [12.0, 11.0, 10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0];
        let corr = pearson_correlation(&a, &b);
        assert!(corr < 0.0, "反向序列应为负相关: {corr}");
    }

    #[test]
    fn test_detect_key_silence() {
        let mono = vec![0.0f32; 44100 * 2];
        let (key, energy) = detect_key(&mono, 44100);
        assert!(key.is_none(), "静音应无调性");
        assert!(energy.is_none(), "静音应无能量");
    }
}
