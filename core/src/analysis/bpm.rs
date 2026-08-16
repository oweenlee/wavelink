//! BPM 检测：谱通量 onset 包络 + 自相关 + 梳状滤波 + 对数正态速度先验。
//!
//! 朴素自相关在真实歌曲上大量出现倍频/半频错误（把 140 BPM 的舞曲
//! 报成 70，或把 97 BPM 的慢歌报成 194）。改进：
//! 1. 谱通量 onset：比 RMS 能量差分能捕捉更多真实起音（频谱变化但
//!    总能量不变的起音，如拨弦/军鼓）；
//! 2. 梳状滤波：候选周期 L 的得分累加 L、2L、3L 处的自相关
//!    （真实节拍的整数倍周期必然也有相关性），锁定基频；
//! 3. 对数正态先验：以 120 BPM 为中心（σ≈0.35 octave），
//!    在倍频歧义时偏向人耳更常感知的中段速度；
//! 4. 抛物线插值细化，消除 lag 整数量化误差。

use realfft::RealFftPlanner;

const ONSET_FRAME: usize = 1024;
const ONSET_HOP: usize = 512;

/// 谱通量 onset 包络（半波整流）
fn onset_envelope(samples: &[f32]) -> Vec<f32> {
    let mut planner = RealFftPlanner::new();
    let fft = planner.plan_fft_forward(ONSET_FRAME);
    let mut window = vec![0.0f32; ONSET_FRAME];
    for (i, w) in window.iter_mut().enumerate() {
        let angle = 2.0 * std::f32::consts::PI * i as f32 / (ONSET_FRAME - 1) as f32;
        *w = 0.5 * (1.0 - angle.cos());
    }

    let n_bins = ONSET_FRAME / 2 + 1;
    let mut prev_mag = vec![0.0f32; n_bins];
    let mut mags = vec![0.0f32; n_bins];
    let mut spectrum = vec![realfft::num_complex::Complex::new(0.0, 0.0); n_bins];
    let mut onset = Vec::new();

    let mut start = 0;
    while start + ONSET_FRAME <= samples.len() {
        let mut frame: Vec<f32> = (0..ONSET_FRAME)
            .map(|i| samples[start + i] * window[i])
            .collect();
        if fft.process(&mut frame, &mut spectrum).is_ok() {
            for (b, c) in spectrum.iter().enumerate() {
                mags[b] = c.norm();
            }
            let flux: f32 = mags
                .iter()
                .zip(prev_mag.iter())
                .map(|(m, p)| (*m - *p).max(0.0))
                .sum();
            onset.push(flux);
            prev_mag.copy_from_slice(&mags);
        }
        start += ONSET_HOP;
    }
    onset
}

/// 对数正态速度先验（以 120 BPM 为中心），倍频歧义时偏向中段速度。
fn tempo_prior(bpm: f32) -> f32 {
    (-0.5 * ((bpm / 120.0).ln() / 0.35).powi(2)).exp()
}

/// 候选 lag 的最终得分：梳状滤波 × 速度先验。
fn score_at(corr: &[f32], lag: usize, corr_hi: usize, frame_rate: f32) -> f32 {
    let bpm = frame_rate * 60.0 / lag as f32;
    comb_at(corr, lag, corr_hi) * tempo_prior(bpm)
}

/// 检测 BPM：谱通量 onset + 自相关梳状滤波 + 速度先验。
/// 返回 None 表示静音或无稳定节拍。
pub fn detect_bpm(samples: &[f32], sample_rate: u32) -> Option<f32> {
    detect_bpm_with_confidence(samples, sample_rate).0
}

/// 检测 BPM 及其置信度（0~1）。
///
/// 置信度 = 周期强度 × 峰独占度：
/// - 周期强度：`best_raw / corr0`，衡量 onset 包络的自相关峰有多强；
/// - 峰独占度：`1 - second/best`，次优峰越接近（如倍频/半频歧义）越低。
///
/// 这是「规律度 + 无歧义」的把握度，不是与人工标注对拍的正确率。
pub fn detect_bpm_with_confidence(
    samples: &[f32],
    sample_rate: u32,
) -> (Option<f32>, Option<f32>) {
    let frame_size = ONSET_FRAME;
    let hop_size = ONSET_HOP;

    if samples.len() < frame_size {
        return (None, None);
    }

    let onset = onset_envelope(samples);

    if onset.len() < 20 {
        return (None, None);
    }

    let n = onset.len();
    let mean = onset.iter().sum::<f32>() / n as f32;

    let frame_rate = sample_rate as f32 / hop_size as f32;
    // 候选速度范围 60-200 BPM（信号太短时收紧慢速端）
    let cand_lo = ((frame_rate * 60.0 / 200.0).round() as usize).max(1); // 200 BPM
    let cand_hi = ((frame_rate * 60.0 / 60.0).round() as usize).min(n / 2); // 60 BPM
                                                                            // 自相关需要算到 3 倍候选周期（梳状滤波用），但不超过信号一半
    let corr_hi = (cand_hi * 3).min(n / 2);
    if cand_lo >= cand_hi || corr_hi <= cand_lo {
        return (None, None);
    }

    // 中心削波：抑制弱拍噪声
    let centered: Vec<f32> = onset.iter().map(|x| x - mean).collect();
    let threshold = centered.iter().map(|x| x.abs()).sum::<f32>() / n as f32 * 0.5;
    let clipped: Vec<f32> = centered
        .iter()
        .map(|&x| if x > threshold { x - threshold } else { 0.0 })
        .collect();

    // 零滞后自相关 = 削波信号能量，用于归一化周期强度
    let corr0 = clipped.iter().map(|x| x * x).sum::<f32>() / n as f32;
    if corr0 < 1e-12 {
        return (None, None);
    }

    // 自相关（归一化到帧数，跨 lag 可比）
    let mut corr = vec![0.0f32; corr_hi + 1];
    for lag in cand_lo..=corr_hi {
        let mut c = 0.0f32;
        for i in 0..(n - lag) {
            c += clipped[i] * clipped[i + lag];
        }
        corr[lag] = c / (n - lag) as f32;
    }

    // 梳状得分 × 速度先验
    let mut best_score = 0.0f32;
    let mut best_lag = cand_lo;
    let mut best_raw = 0.0f32;
    for lag in cand_lo..=cand_hi {
        let score = score_at(&corr, lag, corr_hi, frame_rate);
        if score > best_score {
            best_score = score;
            best_lag = lag;
            best_raw = corr[lag];
        }
    }

    // 静音/无节拍：自相关本身接近零
    if best_raw < 1e-6 {
        return (None, None);
    }

    // 次优峰：排除最优 lag 邻域（±12.5%）后再取最大，捕捉倍频/半频竞争峰
    // 而非同一峰旁的相邻 lag（相邻 lag 得分几乎相同，会稀释 margin）。
    let mut second_score = 0.0f32;
    let sep = (best_lag as f32 / 8.0).max(1.0);
    for lag in cand_lo..=cand_hi {
        if (lag as f32 - best_lag as f32).abs() < sep {
            continue;
        }
        let score = score_at(&corr, lag, corr_hi, frame_rate);
        if score > second_score {
            second_score = score;
        }
    }

    // 抛物线插值细化峰值位置
    let lag_f = if best_lag > cand_lo && best_lag < cand_hi {
        let y0 = comb_at(&corr, best_lag - 1, corr_hi);
        let y1 = comb_at(&corr, best_lag, corr_hi);
        let y2 = comb_at(&corr, best_lag + 1, corr_hi);
        let den = y0 - 2.0 * y1 + y2;
        if den.abs() > 1e-12 {
            best_lag as f32 + 0.5 * (y0 - y2) / den
        } else {
            best_lag as f32
        }
    } else {
        best_lag as f32
    };

    let bpm = frame_rate * 60.0 / lag_f.max(1.0);

    let salience = (best_raw / corr0).clamp(0.0, 1.0);
    let margin = if best_score > 1e-12 {
        (1.0 - second_score / best_score).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let confidence = (salience * margin).clamp(0.0, 1.0);

    (Some((bpm * 10.0).round() / 10.0), Some(confidence))
}

fn comb_at(corr: &[f32], lag: usize, corr_hi: usize) -> f32 {
    const COMB_WEIGHTS: [f32; 3] = [1.0, 0.8, 0.64];
    let mut s = 0.0f32;
    for (k, w) in COMB_WEIGHTS.iter().enumerate() {
        let l = lag * (k + 1);
        if l <= corr_hi && l < corr.len() {
            s += w * corr[l];
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn impulse_train(bpm: f32, secs: u32, sr: u32) -> Vec<f32> {
        let len = sr as usize * secs as usize;
        let mut samples = vec![0.0f32; len];
        let interval = (sr as f64 * 60.0 / bpm as f64) as usize;
        let mut pos = 0;
        while pos < len {
            for i in 0..64 {
                if pos + i < len {
                    samples[pos + i] = 0.5 - (i as f32 / 64.0 * std::f32::consts::PI).cos() * 0.5;
                }
            }
            pos += interval;
        }
        samples
    }

    #[test]
    fn test_detect_bpm_with_impulse_train() {
        let samples = impulse_train(120.0, 10, 44100);
        let bpm = detect_bpm(&samples, 44100).expect("应有结果");
        assert!((bpm - 120.0).abs() < 2.0, "BPM 应接近 120，实际 {bpm}");
    }

    #[test]
    fn test_detect_bpm_slow_song() {
        // 75 BPM 慢歌：不应被先验拉到 150
        let samples = impulse_train(75.0, 20, 44100);
        let bpm = detect_bpm(&samples, 44100).expect("应有结果");
        assert!(
            (bpm - 75.0).abs() < 2.0,
            "75 BPM 脉冲应检出 ~75，实际 {bpm}"
        );
    }

    #[test]
    fn test_detect_bpm_silence() {
        let samples = vec![0.0f32; 44100 * 5];
        let bpm = detect_bpm(&samples, 44100);
        assert!(bpm.is_none(), "静音应无 BPM");
    }
}
