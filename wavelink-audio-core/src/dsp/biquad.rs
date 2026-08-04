//! IIR 双二阶滤波器（Biquad）
//!
//! 传输函数：y\[n\] = b0\*x\[n\] + b1\*x\[n-1\] + b2\*x\[n-2\] - a1\*y\[n-1\] - a2\*y\[n-2\]
//! 所有系数按 audio EQ cookbook (Robert Bristow-Johnson) 计算。
//! 定点无关，用 f32 处理；实时回调中零分配（状态是固定大小字段）。

/// 单个双二阶滤波器（Direct Form 1 状态）
#[derive(Clone)]
pub struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl Biquad {
    /// 用原始系数构造（a0 已归一化为 1）
    pub fn new(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Self {
        Biquad { b0, b1, b2, a1, a2, x1: 0.0, x2: 0.0, y1: 0.0, y2: 0.0 }
    }

    /// Peaking EQ（参数均衡，RBJ audio EQ cookbook）。
    /// freq 中心频率，sample_rate 采样率，gain_db 增益(dB)，q 品质因数（自动防零）。
    pub fn peaking(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self {
        let q = q.max(0.001);
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let b0 = 1.0 + alpha * a;
        let b1 = -2.0 * cos_w0;
        let b2 = 1.0 - alpha * a;
        let a0 = 1.0 + alpha / a;
        let a1 = -2.0 * cos_w0;
        let a2 = 1.0 - alpha / a;
        Biquad::new(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// 低通（用于 Crossfeed 的高频截断）
    pub fn lowpass(freq: f32, sample_rate: f32, q: f32) -> Self {
        let q = q.max(0.001);
        let w0 = 2.0 * std::f32::consts::PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let b1 = 1.0 - cos_w0;
        let b0 = b1 / 2.0;
        let b2 = b0;
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cos_w0;
        let a2 = 1.0 - alpha;
        Biquad::new(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// 高通（DC offset 滤除，~2Hz）
    pub fn highpass(freq: f32, sample_rate: f32, q: f32) -> Self {
        let q = q.max(0.001);
        let w0 = 2.0 * std::f32::consts::PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let b0 = (1.0 + cos_w0) / 2.0;
        let b1 = -(1.0 + cos_w0);
        let b2 = b0;
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cos_w0;
        let a2 = 1.0 - alpha;
        Biquad::new(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// 低频搁架（Low Shelf，RBJ audio EQ cookbook，Q 定义 alpha）。
    /// freq 拐点频率，gain_db 低频增益，q 控制过渡陡峭度（AutoEQ/EqualizerAPO 约定）。
    pub fn low_shelf(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self {
        let q = q.max(0.001);
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let b0 = a * ((a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha);
        let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0);
        let b2 = a * ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha);
        let a0 = (a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha;
        let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0);
        let a2 = (a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha;
        Biquad::new(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// 高频搁架（High Shelf，RBJ audio EQ cookbook，Q 定义 alpha）。
    /// freq 拐点频率，gain_db 高频增益，q 控制过渡陡峭度。
    pub fn high_shelf(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self {
        let q = q.max(0.001);
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let b0 = a * ((a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha);
        let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0);
        let b2 = a * ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha);
        let a0 = (a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha;
        let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0);
        let a2 = (a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha;
        Biquad::new(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// 处理一个样本（单声道）
    #[inline]
    pub fn process(&mut self, x0: f32) -> f32 {
        let y0 = self.b0 * x0 + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x0;
        self.y2 = self.y1;
        self.y1 = y0;
        y0
    }

    /// 原地处理一段样本（单声道）
    pub fn process_slice(&mut self, buf: &mut [f32]) {
        for x in buf.iter_mut() {
            *x = self.process(*x);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1kHz 正弦波经 +6dB peaking(1kHz) 后幅值应约 +6dB
    #[test]
    fn test_peaking_gain_6db() {
        let sr = 44100.0f32;
        let mut bq = Biquad::peaking(1000.0, sr, 6.0, 1.0);
        // 生成 1kHz 正弦波，跑稳态后测峰值
        let mut out_peak = 0.0f32;
        let mut in_peak = 0.0f32;
        for n in 0..44100 {
            let t = n as f32 / sr;
            let x = (2.0 * std::f32::consts::PI * 1000.0 * t).sin() * 0.5;
            let y = bq.process(x);
            if n > 1000 {
                in_peak = in_peak.max(x.abs());
                out_peak = out_peak.max(y.abs());
            }
        }
        let gain = 20.0 * out_peak.log10() - 20.0 * in_peak.log10();
        assert!((gain - 6.0).abs() < 0.2, "peaking 增益偏差过大: {gain} dB");
    }

    #[test]
    fn test_highpass_attenuates_dc() {
        let sr = 44100.0f32;
        // 用 20Hz 截止（周期 50ms），跑 5 秒充分 settle
        let mut bq = Biquad::highpass(20.0, sr, 0.707);
        let mut out = 0.0;
        for _ in 0..(sr as usize * 5) {
            out = bq.process(1.0);
        }
        assert!(out.abs() < 0.05, "HPF 未滤除直流: {out}");
    }
}
