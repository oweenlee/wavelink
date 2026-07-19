//! 高级抖动器：TPDF + ATH 噪声整形
//!
//! 32-bit float → 整数转换前叠加 TPDF 噪声，用可忽略的低底噪
//! 替代不可忽略的量化谐波失真。
//!
//! 可选 ATH（绝对听觉阈值）噪声整形：
//!   将量化噪声推向高频（人耳不敏感区域），以 2nd-order
//!   NTF = (1 - z^-1)^2 实现，约 12dB/oct 高频提升，
//!   在 20kHz 处可实现 ~15dB 额外噪声抑制。

/// 2nd-order 噪声整形状态
#[derive(Clone, Default)]
struct ShaperState {
    e1: f32,
    e2: f32,
}

/// 抖动器
pub struct Dither {
    /// 每个声道一条独立噪声序列 + 当前位置
    noise: Vec<(Vec<f32>, usize)>,
    amplitude: f32,
    /// 量化比例（半幅），用于噪声整形路径的显式量化
    scale: f32,
    /// 是否启用 ATH 噪声整形
    noise_shaping: bool,
    /// 每声道噪声整形状态
    shaper: Vec<ShaperState>,
}

impl Dither {
    /// amp: 抖动幅度（单位：LSB 占比，通常 1.0 LSB）
    /// bits: 目标位深 (16/24)
    pub fn new(channels: usize, bits: u32, amp_lsb: f32) -> Self {
        let scale = (1u32 << (bits - 1)) as f32;
        let amplitude = amp_lsb / scale;
        let mut rng = fastrand::Rng::new();
        let noise = (0..channels)
            .map(|_| {
                let seq: Vec<f32> = (0..65536).map(|_| rng.f32()).collect();
                (seq, 0)
            })
            .collect();
        Dither {
            noise,
            amplitude,
            scale,
            noise_shaping: false,
            shaper: vec![ShaperState::default(); channels],
        }
    }

    /// 启用/禁用 ATH 噪声整形
    pub fn set_noise_shaping(&mut self, enabled: bool) {
        self.noise_shaping = enabled;
        if enabled {
            // 重置整形状态，避免瞬态
            for s in &mut self.shaper {
                *s = ShaperState::default();
            }
        }
    }

    /// 对单声道缓冲注入抖动（就地）
    /// ch: 声道索引
    pub fn process(&mut self, buf: &mut [f32], ch: usize) {
        let idx = ch % self.noise.len();
        let (seq, pos) = &mut self.noise[idx];
        let amp = self.amplitude;

        if self.noise_shaping {
            // ——— ATH 噪声整形路径 ———
            // NTF = (1 - z^-1)^2
            // 反馈: h[n] = 2*e[n-1] - e[n-2]
            // v = x + d - h ; y = Q(v) ; e = y - v
            let scale = self.scale;
            let inv_scale = 1.0 / scale;
            let state = &mut self.shaper[idx];

            for s in buf.iter_mut() {
                // TPDF 噪声
                let r1 = seq[*pos];
                *pos = (*pos + 1) % seq.len();
                let r2 = seq[*pos];
                *pos = (*pos + 1) % seq.len();
                let tpdf = (r1 + r2 - 1.0) * amp;

                // 噪声整形反馈: h = 2*e1 - e2
                let h = 2.0 * state.e1 - state.e2;

                // 叠加抖动并量化
                let v = *s + tpdf - h;
                let q = (v * scale).round();
                let y = q * inv_scale;

                // 量化误差
                let e = y - v;

                // 更新状态
                state.e2 = state.e1;
                state.e1 = e;

                *s = y;
            }
        } else {
            // ——— 纯 TPDF 路径（默认） ———
            for s in buf.iter_mut() {
                let r1 = seq[*pos];
                *pos = (*pos + 1) % seq.len();
                let r2 = seq[*pos];
                *pos = (*pos + 1) % seq.len();
                let tpdf = r1 + r2 - 1.0;
                *s += tpdf * amp;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tpdf_statistics() {
        let mut d = Dither::new(1, 24, 1.0);
        let mut buf = vec![0.0f32; 200000];
        d.process(&mut buf, 0);
        let mean = buf.iter().sum::<f32>() / buf.len() as f32;
        assert!(mean.abs() < 0.05, "TPDF 均值偏差过大: {mean}");
    }

    #[test]
    fn test_noise_shaping_quantizes() {
        let mut d = Dither::new(1, 24, 1.0);
        d.set_noise_shaping(true);
        // 输入一个 24-bit 无法精确表示的值
        let mut buf = vec![0.3333333333f32; 100];
        d.process(&mut buf, 0);
        // 输出应被量化到 24-bit 网格
        let scale = (1u32 << 23) as f32;
        for &s in &buf {
            let q = (s * scale).round();
            let reconstructed = q / scale;
            assert!(
                (s - reconstructed).abs() < 1e-8,
                "噪声整形后未正确量化: {s} vs {reconstructed}"
            );
        }
    }

    #[test]
    fn test_noise_shaping_error_feedback() {
        // 验证误差反馈不导致发散
        let mut d = Dither::new(1, 24, 1.0);
        d.set_noise_shaping(true);
        let mut buf = vec![0.0f32; 10000];
        d.process(&mut buf, 0);
        for &s in &buf {
            assert!(s.is_finite(), "噪声整形输出非有限值: {s}");
            assert!(s.abs() < 1.0, "噪声整形输出过大: {s}");
        }
    }
}
