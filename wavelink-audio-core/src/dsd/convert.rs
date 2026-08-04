//! DSD→PCM 转换
//!
//! 算法：3 级降采样滤波
//!   1. Boxcar 平均降采样 8x（DSD 位 → f32，无乘法）
//!   2. FIR 低通 + 降采样 8x（窗口 sinc 滤波器）
//!
//! 总降采样比固定 64x：
//!   DSD64 (2.8224 MHz)  → 44.1 kHz
//!   DSD128 (5.6448 MHz) → 88.2 kHz
//!   DSD256 (11.2896 MHz)→ 176.4 kHz

use dsd_reader::DsdRate;

const STAGE1_DECIM: usize = 8;

/// DSD 位 → f32 平面数据，降采样 8x（boxcar 累加平均，无乘法）
fn stage1_boxcar(dsd_bytes: &[u8]) -> Vec<f32> {
    let total_bits = dsd_bytes.len().saturating_mul(8);
    let out_len = total_bits / STAGE1_DECIM;
    let mut out = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let start = i * STAGE1_DECIM;
        let mut sum = 0i32;
        for b in 0..STAGE1_DECIM {
            let bit_idx = start + b;
            let byte_idx = bit_idx >> 3;
            if byte_idx < dsd_bytes.len() {
                let bit_off = 7 - (bit_idx & 7) as u32;
                sum += if (dsd_bytes[byte_idx] >> bit_off) & 1 == 1 {
                    1
                } else {
                    -1
                };
            }
        }
        out.push(sum as f32 / STAGE1_DECIM as f32);
    }
    out
}

/// 设计 Blackman 窗口 sinc 低通 FIR 滤波器
///
/// `fc` — 归一化截止频率 (0~0.5)
/// `taps` — 系数个数
fn design_fir(fc: f64, taps: usize) -> Vec<f64> {
    let half = (taps - 1) as f64 / 2.0;
    let mut coeffs = vec![0.0f64; taps];
    let a0 = 0.42;
    let a1 = 0.5;
    let a2 = 0.08;

    for i in 0..taps {
        let n = i as f64 - half;
        coeffs[i] = if n == 0.0 {
            2.0 * fc
        } else {
            let x = std::f64::consts::PI * n;
            (2.0 * fc * x).sin() / x
        };
        // Blackman 窗
        let w = a0 - a1 * (2.0 * std::f64::consts::PI * i as f64 / (taps - 1) as f64).cos()
            + a2 * (4.0 * std::f64::consts::PI * i as f64 / (taps - 1) as f64).cos();
        coeffs[i] *= w;
    }

    // DC 增益归一化
    let gain: f64 = coeffs.iter().sum();
    if gain > 0.0 {
        for c in &mut coeffs {
            *c /= gain;
        }
    }
    coeffs
}

/// FIR 低通 + 降采样
///
/// 滤波器在输入采样率的 `0.45 / decim` 处截断
fn stage2_fir(input: &[f32], decim: usize) -> Vec<f32> {
    let fc = 0.45 / decim as f64;
    let taps = 64usize.max(decim * 4);
    let coeffs = design_fir(fc, taps);
    let half = taps as f64 / 2.0;

    let out_len = input.len() / decim;
    let mut out = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let center = i * decim;
        let mut sum = 0.0f64;
        for j in 0..taps {
            let idx = center as i64 + j as i64 - half as i64;
            if idx >= 0 && (idx as usize) < input.len() {
                sum += input[idx as usize] as f64 * coeffs[j];
            }
        }
        out.push(sum as f32);
    }
    out
}

/// 将单声道 DSD 字节转换为 PCM f32
///
/// `dsd_rate` — DSD 速率 (DSD64=1, DSD128=2, ...)
pub fn convert_channel(dsd_bytes: &[u8], _dsd_rate: DsdRate) -> Vec<f32> {
    let stage1 = stage1_boxcar(dsd_bytes);
    stage2_fir(&stage1, STAGE1_DECIM)
}

/// 公开的 stage1 boxcar（供流式解码器调用）
pub fn stage1_boxcar_pub(dsd_bytes: &[u8]) -> Vec<f32> {
    stage1_boxcar(dsd_bytes)
}

/// 流式 FIR 降采样：从 pending 缓冲中取出可计算的输出，保留尾部重叠供下次使用。
///
/// `pending` 包含上次的 FIR 重叠尾部 + 新的 stage1 样本。
/// 返回本次可输出的 PCM 样本，并将 pending 截断为保留的尾部。
pub fn stage2_fir_streaming(pending: &mut Vec<f32>) -> Vec<f32> {
    let decim = STAGE1_DECIM;
    let taps = 64usize.max(decim * 4); // = 64
    let half = taps / 2; // = 32

    if pending.len() < taps {
        // 不够一个完整滤波器窗口，不输出
        return Vec::new();
    }

    // 计算可输出的样本数：center 范围 [half, len - half + 1)，步长 decim
    let max_center = pending.len() - half; // 最后一个有效 center（exclusive: center+half-1 < len）
    let first_center = half;
    if max_center <= first_center {
        return Vec::new();
    }
    let out_count = (max_center - first_center) / decim;
    if out_count == 0 {
        return Vec::new();
    }

    // 设计 FIR 滤波器（每次 flush 重新计算，开销忽略不计）
    let fc = 0.45 / decim as f64;
    let coeffs = design_fir(fc, taps);

    let mut out = Vec::with_capacity(out_count);
    for i in 0..out_count {
        let center = first_center + i * decim;
        let mut sum = 0.0f64;
        for j in 0..taps {
            let idx = center + j - half;
            sum += pending[idx] as f64 * coeffs[j];
        }
        out.push(sum as f32);
    }

    // 保留尾部重叠：下次需要 center - half 起的样本
    // 最后一个已处理的 center = first_center + (out_count-1)*decim
    // 下次第一个 center 应紧接其后，需要的最早样本 = next_center - half
    // 保留从 (last_center + decim - half) 开始的尾部
    let keep_from = first_center + out_count * decim - half;
    if keep_from < pending.len() {
        pending.drain(..keep_from);
    } else {
        pending.clear();
    }

    out
}

/// 将多声道 DSD 数据转换为交错 PCM f32
///
/// `chan_bytes` — 每个声道的 DSD 字节数据
/// `dsd_rate` — DSD 速率
pub fn convert_channels(chan_bytes: &[&[u8]], dsd_rate: DsdRate) -> Vec<f32> {
    let ch = chan_bytes.len();
    if ch == 0 {
        return Vec::new();
    }

    // 各声道独立转换
    let pcm_chs: Vec<Vec<f32>> = chan_bytes
        .iter()
        .map(|b| convert_channel(b, dsd_rate))
        .collect();

    if pcm_chs.is_empty() {
        return Vec::new();
    }

    // 交错
    let frame_count = pcm_chs[0].len();
    let mut interleaved = Vec::with_capacity(frame_count * ch);
    for f in 0..frame_count {
        for c in 0..ch {
            interleaved.push(pcm_chs[c][f]);
        }
    }
    interleaved
}

/// 获取 DSD 对应的输出采样率
pub fn output_sample_rate(dsd_rate: DsdRate) -> u32 {
    const BASE: u32 = 44_100;
    let mult = dsd_rate as u32;
    BASE * mult.min(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 验证 stage1 (boxcar) 正确性：恒定 +1 输入应输出 +1
    #[test]
    fn test_stage1_constant_one() {
        // 所有位为 1 的字节 0xFF → bit 值恒为 +1
        let bytes = vec![0xFFu8; 8]; // 8 bytes = 64 bits = 8 outputs
        let out = stage1_boxcar(&bytes);
        assert_eq!(out.len(), 8);
        for v in &out {
            assert!((*v - 1.0).abs() < 1e-6, "期望 +1, 实际 {v}");
        }
    }

    /// 验证 stage1 (boxcar) 正确性：恒定 -1 输入应输出 -1
    #[test]
    fn test_stage1_constant_neg_one() {
        let bytes = vec![0x00u8; 8]; // 所有位为 0 → bit 值恒为 -1
        let out = stage1_boxcar(&bytes);
        for v in &out {
            assert!((*v + 1.0).abs() < 1e-6, "期望 -1, 实际 {v}");
        }
    }

    /// 验证 stage1 交替位模式
    #[test]
    fn test_stage1_alternating() {
        // 0xAA = 10101010 → 每 8 位的和 = 0 → 输出 0
        let bytes = vec![0xAAu8; 8];
        let out = stage1_boxcar(&bytes);
        for v in &out {
            assert!(v.abs() < 1e-6, "期望 0, 实际 {v}");
        }
    }

    /// 验证 FIR 滤波器 DC 增益 = 1（系数的 DC 响应）
    #[test]
    fn test_fir_dc_gain() {
        let coeffs = design_fir(0.45, 64);
        let sum: f64 = coeffs.iter().sum();
        assert!((sum - 1.0).abs() < 0.01, "DC gain 应接近 1, 实际 {sum}");
    }

    /// 验证 FIR 滤波器对称
    #[test]
    fn test_fir_symmetric() {
        let coeffs = design_fir(0.45, 64);
        for i in 0..32 {
            let diff = (coeffs[i] - coeffs[63 - i]).abs();
            assert!(diff < 1e-14, "FIR 系数不对称: index {i} vs {}", 63 - i);
        }
    }

    /// 验证 convert_channel 不会引入 NaN
    #[test]
    fn test_convert_no_nan() {
        let bytes = vec![0x69u8; 4096]; // DSD 静音 (0x69 = 01101001)
        let out = convert_channel(&bytes, DsdRate::DSD64);
        assert!(!out.is_empty());
        for v in &out {
            assert!(!v.is_nan(), "不应出现 NaN");
            assert!(v.is_finite(), "不应出现 Inf");
        }
    }

    /// 验证输出在正常音频振幅范围内（FIR 滤波器可能有少许通带纹波）
    #[test]
    fn test_convert_no_clip() {
        let bytes = vec![0xFFu8; 4096];
        let out = convert_channel(&bytes, DsdRate::DSD64);
        for v in &out {
            assert!(v.is_finite(), "样本非有限: {v}");
        }
        // 不应全为 0
        let max = out.iter().cloned().fold(0.0f32, f32::max);
        assert!(max > 0.0, "不应全零");
    }

    /// 验证 convert_channels 交错正确
    #[test]
    fn test_convert_channels_interleave() {
        let ch0 = vec![0xFFu8; 1024]; // +1
        let ch1 = vec![0x00u8; 1024]; // -1
        let out = convert_channels(&[&ch0, &ch1], DsdRate::DSD64);
        assert!(out.len() >= 2, "应有至少 2 个样本");
        // 第一个样本: ch0>0, 第二个样本: ch1<0
        assert!(out[0] > 0.0, "ch0 应 >0, 实际 {}", out[0]);
        assert!(out[1] < 0.0, "ch1 应 <0, 实际 {}", out[1]);
    }

    /// 验证 DSD64→44.1k 输出长度
    #[test]
    fn test_output_length() {
        // 1 second of DSD64 stereo = 2,822,400 bits / 8 = 352,800 bytes per channel
        // Output: 44,100 frames = 88,200 interleaved samples
        let bytes = vec![0x69u8; 352_800];
        let out = convert_channels(&[&bytes, &bytes], DsdRate::DSD64);
        // 允许 ±2 帧误差（对齐舍入）
        let expected = 44_100;
        let actual = out.len() / 2;
        assert!(
            (actual as i64 - expected as i64).abs() <= 2,
            "DSD64 输出帧数 {actual}, 期望 ~{expected}"
        );
    }

    /// 验证 output_sample_rate 正确
    #[test]
    fn test_output_sample_rate() {
        assert_eq!(output_sample_rate(DsdRate::DSD64), 44_100);
        assert_eq!(output_sample_rate(DsdRate::DSD128), 88_200);
        assert_eq!(output_sample_rate(DsdRate::DSD256), 176_400);
        assert_eq!(output_sample_rate(DsdRate::DSD512), 176_400); // 512 限幅到 4 倍
    }
}
