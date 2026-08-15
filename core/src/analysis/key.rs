//! 调性检测：Chromagram + Krumhansl-Schmuckler 识别大小调。

use realfft::RealFftPlanner;

/// Krumhansl-Schmuckler 调性 profiles（对于 C 大调 / A 小调）
const KS_MAJOR: [f32; 12] = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
// Krumhansl-Kessler (1982) 小调 probe-tone profile 原始值
const KS_MINOR: [f32; 12] = [
    6.33, 2.68, 3.52, 5.38, 2.60, 4.00, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const NOTE_NAMES: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];

/// 按根音旋转 profile：返回 root 调的模板，即 out[i] = profile[(i - root) mod 12]
/// （root 位置的权重应来自 profile 的根音分量 profile[0]）
fn circ_shift(arr: &[f32; 12], shift: usize) -> [f32; 12] {
    let mut out = [0.0f32; 12];
    for i in 0..12 {
        out[i] = arr[(i + 12 - shift) % 12];
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
    let low_bin = (65.0 / freq_per_bin).floor() as usize;
    let high_bin = ((2100.0 / freq_per_bin).ceil() as usize).min(frame_size / 2);
    if high_bin < low_bin + 6 {
        return None;
    }
    let mut mags = vec![0.0f32; frame_size / 2 + 1];
    let mut frame_chroma: [f32; 12];

    for start in (0..mono.len().saturating_sub(frame_size)).step_by(hop_size) {
        let mut frame = Vec::with_capacity(frame_size);
        for i in 0..frame_size {
            frame.push(mono[start + i] * window[i]);
        }

        let mut spectrum =
            vec![realfft::num_complex::Complex::new(0.0f32, 0.0f32); frame_size / 2 + 1];
        if fft.process(&mut frame, &mut spectrum).is_err() {
            continue;
        }
        for (b, c) in spectrum.iter().enumerate() {
            mags[b] = c.norm();
        }

        // 谱峰筛选：只统计局部极大且足够显著的 bin，
        // 滤除宽带噪声与谐波裙边（泛音污染是 FFT chroma 的主要误差源）
        let frame_max = mags[low_bin..=high_bin]
            .iter()
            .cloned()
            .fold(0.0f32, f32::max);
        if frame_max < 1e-8 {
            continue;
        }
        frame_chroma = [0.0f32; 12];
        for bin in (low_bin + 3)..=(high_bin - 3) {
            let m = mags[bin];
            if m < frame_max * 0.1 {
                continue;
            }
            let is_peak = (1..=3).all(|d| m >= mags[bin - d] && m >= mags[bin + d]);
            if !is_peak {
                continue;
            }
            let freq = bin as f32 * freq_per_bin;
            let midi = 12.0 * (freq / 440.0).log2() + 69.0;
            let semitone = ((midi + 0.5).floor() as i32).rem_euclid(12) as usize;
            // 用幅度（非功率），避免最强泛音列压倒性主导
            frame_chroma[semitone] += m;
        }

        // 逐帧 L1 归一化，避免长音/响段压倒其他帧
        let s: f32 = frame_chroma.iter().sum();
        if s > 1e-10 {
            for c in &mut frame_chroma {
                *c /= s;
            }
            for i in 0..12 {
                chroma[i] += frame_chroma[i];
            }
            frames += 1;
        }
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

    // 置信度门槛：相关性过低（如纯打击乐/噪声）不展示调性，
    // 避免给出误导性结果
    if best_corr < 0.35 {
        return (None, Some(energy_of(mono)));
    }

    // energy: 信号平均 RMS 的对数
    let energy_norm = energy_of(mono);

    (Some(key), Some(energy_norm))
}

/// RMS → 0~1 归一化能量
fn energy_of(mono: &[f32]) -> f32 {
    let energy = (mono.iter().map(|s| s * s).sum::<f32>() / mono.len() as f32 + 1e-10)
        .sqrt()
        .max(1e-10);
    let energy_db = 20.0 * energy.log10();
    ((energy_db + 60.0) / 60.0).clamp(0.0, 1.0)
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
        let arr = [
            1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0,
        ];
        // shift=1：out[i] = arr[(i+11)%12]，即模板整体右移一位
        let shifted = circ_shift(&arr, 1);
        assert_eq!(shifted[0], 12.0);
        assert_eq!(shifted[1], 1.0);
        assert_eq!(shifted[2], 2.0);
        assert_eq!(shifted[11], 11.0);
        // root=0 应原样返回
        let same = circ_shift(&arr, 0);
        assert_eq!(same, arr);
    }

    #[test]
    fn test_correlation_identity() {
        let a = [
            1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0,
        ];
        let corr = pearson_correlation(&a, &a);
        assert!((corr - 1.0).abs() < 1e-6, "自相关应为 1: {corr}");
    }

    #[test]
    fn test_correlation_negative() {
        let a = [
            1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0,
        ];
        let b = [
            12.0, 11.0, 10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0,
        ];
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
