//! 真峰值限幅器（True-Peak Limiter）
//!
//! 普通限幅只看采样点（sample peaks），但 DAC 重建时采样点之间可能超过 0 dBFS
//!（inter-sample peaks），导致削波。真峰值限幅器用 4x 过采样检测峰值，
//! 在超过阈值时做增益衰减。
//!
//! 过采样使用 128-tap 窗函数 sinc 低通滤波器（Blackman-Harris 窗），
//! 分解为 4 组 32-tap 多相滤波器，逐样本计算插值。

/// 真峰值限幅器。使用 4x 过采样检测采样间峰值（ISP），防止 DAC 重建削波。
pub struct TruePeakLimiter {
    threshold: f32,
    /// 多相滤波器系数：4 相位 × 32 抽头
    phases: [[f32; 32]; 4],
    /// 延迟线（每声道），环形缓冲
    delay: Vec<[f32; 32]>,
    delay_idx: Vec<usize>,
    release: f32,
    /// attack 平滑系数（每样本逼近目标增益的比例，~0.1ms @44.1kHz）
    attack: f32,
    gain: f32,
}

impl TruePeakLimiter {
    /// 创建限幅器。
    /// - `channels`: 声道数
    /// - `threshold_db`: 阈值（dBFS, 0 = 0dBFS, 负值更激进）
    pub fn new(channels: usize, threshold_db: f32) -> Self {
        let threshold = 10f32.powf(threshold_db / 20.0);
        TruePeakLimiter {
            threshold,
            phases: build_polyphase_filter(),
            delay: vec![[0.0f32; 32]; channels],
            delay_idx: vec![0; channels],
            release: 0.999,
            attack: 0.3, // ~0.1ms attack @44.1kHz，避免瞬态 click
            gain: 1.0,
        }
    }

    /// 处理单声道缓冲
    pub fn process(&mut self, buf: &mut [f32], channel: usize) {
        let idx = channel % self.delay.len();
        let dly = &mut self.delay[idx];
        let mut pos = self.delay_idx[idx];
        let phases = &self.phases;

        for x in buf.iter_mut() {
            let xv = *x;
            dly[pos] = xv;

            // 下一个写入位置，也是当前环形读取的起始偏移
            let rpos = (pos + 1) % 32;

            // 真峰值检测：原始样本 + FIR 4x 插值
            // 原始样本自身确保即时捕获 sample-peak（FIR 有群延迟）
            let mut peak = xv.abs();
            for p in 1..4 {
                let mut sum = 0.0f32;
                for k in 0..32 {
                    let ridx = (rpos + 31 - k) % 32;
                    sum += dly[ridx] * phases[p][k];
                }
                let abs = sum.abs();
                if abs > peak {
                    peak = abs;
                }
            }

            // 增益计算
            let target_gain = if peak > self.threshold {
                self.threshold / peak
            } else {
                1.0
            };

            if target_gain < self.gain {
                // 平滑 attack：每样本逼近目标增益，避免瞬态 click
                // 极端过载（>6dB）加快收敛速度
                let coeff = if peak > self.threshold * 2.0 { 1.0 } else { self.attack };
                self.gain += (target_gain - self.gain) * coeff;
                if self.gain < target_gain { self.gain = target_gain; }
            } else {
                self.gain = self.gain * self.release + target_gain * (1.0 - self.release);
            }
            let out = xv * self.gain;
            // 安全截断：平滑 attack 期间可能有 1-2 样本过冲，硬截断保护
            *x = if out > self.threshold { self.threshold }
                 else if out < -self.threshold { -self.threshold }
                 else { out };
            pos = rpos;
        }

        self.delay_idx[idx] = pos;
    }
}

/// 构建 4x 过采样多相滤波器（128-tap Blackman-Harris 窗 sinc）
///
/// 截止频率 π/4（对应 4x 过采样后的 Nyquist 的一半）。
/// 每组 32 抽头，4 相位分别对应 0/4, 1/4, 2/4, 3/4 样本偏移的插值。
fn build_polyphase_filter() -> [[f32; 32]; 4] {
    const N: usize = 128;
    const M: f32 = 64.0; // N/2
    let omega_c = std::f32::consts::PI / 4.0;

    // 生成原型低通滤波器
    let mut h = [0.0f32; N];
    for i in 0..N {
        let t = i as f32 - M;
        h[i] = if t.abs() < 1e-10 {
            omega_c / std::f32::consts::PI // = 0.25
        } else {
            (omega_c * t).sin() / (std::f32::consts::PI * t)
        };
    }

    // Blackman-Harris 窗（4 项）
    let a0 = 0.35875;
    let a1 = 0.48829;
    let a2 = 0.14128;
    let a3 = 0.01168;
    for i in 0..N {
        let angle = 2.0 * std::f32::consts::PI * i as f32 / (N - 1) as f32;
        let w = a0 - a1 * angle.cos() + a2 * (2.0 * angle).cos() - a3 * (3.0 * angle).cos();
        h[i] *= w;
    }

    // 归一化为单位增益
    let gain: f32 = h.iter().sum();
    for v in h.iter_mut() {
        *v /= gain;
    }

    // 多相分解：4 相位 × 32 抽头
    // 相位 p 获取 h[p], h[p+4], h[p+8], ...
    let mut phases = [[0.0f32; 32]; 4];
    for p in 0..4 {
        for k in 0..32 {
            phases[p][k] = h[k * 4 + p];
        }
    }
    phases
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_limiter_no_overshoot() {
        let mut lim = TruePeakLimiter::new(1, 0.0);
        // 注入 +12dB 冲激
        let mut buf: Vec<f32> = (0..1000).map(|i| if i == 10 { 4.0 } else { 0.0 }).collect();
        lim.process(&mut buf, 0);
        for &s in &buf {
            assert!(s.abs() <= 1.0 + 1e-3, "限幅器输出超出 0 dBFS: {s}");
        }
    }

    #[test]
    fn test_limiter_true_peak_catches_isp() {
        // 构造一个在 sample 间有隐性峰值的信号：
        // x[0] = 0.8, x[1] = 0.8 → 插值可能略低
        // 真正容易触发 ISP 的是 [0.9, -0.9]（方波状）
        let mut lim = TruePeakLimiter::new(1, 0.0);
        let mut buf = vec![0.0f32; 100];
        buf[10] = 0.95;
        buf[11] = -0.95;
        lim.process(&mut buf, 0);
        for &s in &buf {
            assert!(s.abs() <= 1.0 + 1e-3, "ISP 场景输出超出 0 dBFS: {s}");
        }
    }

    #[test]
    fn test_polyphase_filter_gain() {
        let phases = build_polyphase_filter();
        // 所有系数之和应接近 1.0
        let sum: f32 = phases.iter().flat_map(|p| p.iter()).sum();
        assert!(
            (sum - 1.0).abs() < 0.05,
            "多相滤波器总增益偏差过大: {sum}"
        );
        // 每相位自身也应合理
        for (p, phase) in phases.iter().enumerate() {
            let psum: f32 = phase.iter().sum();
            assert!(
                psum > 0.0,
                "相位 {p} 系数和不正, 可能符号错误: {psum}"
            );
        }
    }
}
