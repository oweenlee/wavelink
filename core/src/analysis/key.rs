//! 调性检测：HPCP（谐波折叠）+ 多模板（Krumhansl-Kessler + Temperley）。
//!
//! 与 essentia KeyExtractor 同思路（Gómez 2006 HPCP）：
//! 1. 谐波折叠：每个 FFT bin 按 1/h 权重投给其第 h 次谐波假设的基频
//!    （h=1..4）。消除朴素 FFT chroma 的纯五度混淆——基频的 3 次谐波
//!    恰好高纯五度+八度，折叠后回到基频音级。
//! 2. 36-bin 连续音级映射（每半音 3 bin）+ 线性插值，替代四舍五入
//!    到整数半音，减少调音偏移（非 440）导致的谱峰错位。
//! 3. 帧级 L1 归一化后聚合，尾部再归一化。
//! 4. KS 模板相关取最优；major/minor × 12 根音共 24 候选。

use realfft::RealFftPlanner;

/// Krumhansl-Schmuckler 调性 profiles（Krumhansl-Kessler 1982 原始值）
const KS_MAJOR: [f32; 12] = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const KS_MINOR: [f32; 12] = [
    6.33, 2.68, 3.52, 5.38, 2.60, 4.00, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];

const NOTE_NAMES: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];

/// 分析频率范围（基频）：谐波折叠后 2100 Hz 上限可覆盖 65 Hz 基频的第 5 次谐波
const MIN_FREQ: f32 = 65.0;
const MAX_FREQ: f32 = 2100.0;
/// 谐波折叠阶数（essentia PitchFilterbank 默认 4）
const HARMONICS: usize = 4;

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

/// HPCP chromagram：谐波折叠 + 36-bin 连续映射，聚合后 fold 到 12 音级。
/// [tuning] 为 A4 参考频率（Hz），用于补偿非 440 调音的录音。
fn compute_chromagram_tuned(mono: &[f32], sample_rate: u32, tuning: f32) -> Option<[f32; 12]> {
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

    let n_bins = frame_size / 2 + 1;
    let mut mags = vec![0.0f32; n_bins];
    let mut spectrum = vec![realfft::num_complex::Complex::new(0.0f32, 0.0f32); n_bins];
    let mut hpcp = [0.0f32; 36];
    let mut frame_hpcp: [f32; 36];
    let mut frames = 0usize;

    let freq_per_bin = sample_rate as f32 / frame_size as f32;
    let low_bin = (MIN_FREQ / freq_per_bin).floor() as usize;
    let high_bin = ((MAX_FREQ / freq_per_bin).ceil() as usize).min(n_bins - 1);
    if high_bin < low_bin + 4 {
        return None;
    }

    for start in (0..mono.len().saturating_sub(frame_size)).step_by(hop_size) {
        let mut frame = Vec::with_capacity(frame_size);
        for i in 0..frame_size {
            frame.push(mono[start + i] * window[i]);
        }
        if fft.process(&mut frame, &mut spectrum).is_err() {
            continue;
        }
        for (b, c) in spectrum.iter().enumerate() {
            mags[b] = c.norm();
        }

        // 谐波折叠：bin (freq, mag) 按 1/h 投给其第 h 谐波假设的基频
        frame_hpcp = [0.0f32; 36];
        for bin in low_bin..=high_bin {
            let m = mags[bin];
            if m < 1e-10 {
                continue;
            }
            let freq = bin as f32 * freq_per_bin;
            let midi = 12.0 * (freq / tuning).log2() + 69.0;
            for h in 1..=HARMONICS {
                // 该 bin 是基频 base 的第 h 次谐波 → base_midi = midi - log2(h)*12
                let base_midi = midi - 12.0 * (h as f32).log2();
                let base_freq = tuning * 2f32.powf((base_midi - 69.0) / 12.0);
                if !(MIN_FREQ..=MAX_FREQ).contains(&base_freq) {
                    continue;
                }
                // 36-bin 连续映射（每半音 3 bin，+0.5 使整数 MIDI 落在半音中心），
                // 相邻 bin 线性插值（能量守恒）
                let x = (base_midi + 0.5) * 3.0 - 0.5;
                let i0 = x.floor() as i32;
                let frac = x - i0 as f32;
                let contrib = m / h as f32;
                let idx0 = i0.rem_euclid(36) as usize;
                let idx1 = (i0 + 1).rem_euclid(36) as usize;
                frame_hpcp[idx0] += contrib * (1.0 - frac);
                frame_hpcp[idx1] += contrib * frac;
            }
        }

        // 帧级 L1 归一化，避免响段压倒其他帧
        let s: f32 = frame_hpcp.iter().sum();
        if s > 1e-10 {
            for c in &mut frame_hpcp {
                *c /= s;
            }
            for i in 0..36 {
                hpcp[i] += frame_hpcp[i];
            }
            frames += 1;
        }
    }

    if frames == 0 {
        return None;
    }

    // fold 36 → 12 音级（每 3 bin 一个半音组）
    let mut chroma = [0.0f32; 12];
    for (i, v) in hpcp.iter().enumerate() {
        chroma[i / 3] += v;
    }
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

/// 默认 440 调音（测试/调试用）
fn compute_chromagram(mono: &[f32], sample_rate: u32) -> Option<[f32; 12]> {
    compute_chromagram_tuned(mono, sample_rate, 440.0)
}

/// 调试用：输出 HPCP 12 维音级向量（离线模板权重实验用）
pub fn debug_chromagram(mono: &[f32], sample_rate: u32) -> Option<[f32; 12]> {
    compute_chromagram(mono, sample_rate)
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
        let corr_major = pearson_correlation(&chroma, &circ_shift(&KS_MAJOR, root));
        let corr_minor = pearson_correlation(&chroma, &circ_shift(&KS_MINOR, root));
        if corr_major > best_corr {
            best_corr = corr_major;
            best_root = root;
            best_is_major = true;
        }
        if corr_minor > best_corr {
            best_corr = corr_minor;
            best_root = root;
            best_is_major = false;
        }
    }

    // 置信度门槛：相关性过低（如纯打击乐/噪声）不展示调性，
    // 避免给出误导性结果
    if best_corr < 0.35 {
        return (None, Some(energy_of(mono)));
    }

    let key = format!(
        "{}{}",
        NOTE_NAMES[best_root],
        if best_is_major { "" } else { "m" }
    );

    (Some(key), Some(energy_of(mono)))
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
