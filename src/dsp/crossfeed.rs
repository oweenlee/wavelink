//! Crossfeed（Bauer 算法，基于 bs2b crate）
//!
//! 耳机聆听时左右声道完全分离，缺少音箱摆放时的"串音"，
//! 导致声场不自然、中频凹陷。Bauer 算法把对侧信号经低通+衰减后混入同侧，
//! 模拟音箱串音。
//!
//! 使用 bs2b crate（纯 Rust）替代自研 Biquad + VecDeque 延迟实现，
//! 使用标准化的 CMOY 预设（700Hz 截止, 6.0dB 衰减），
//! 滤波器特性更精准（IIR 双二阶级联），延迟处理更规范。

use bs2b::{Bs2b, Level};

pub struct Crossfeed {
    inner: Bs2b,
}

impl Crossfeed {
    /// mix: 忽略（由 bs2b 的 Level 控制）；cutoff_hz/delay_us: 忽略（由 Level 控制）
    /// 所有参数保留是为了不破坏 pipeline.rs 的调用签名。
    /// 实际行为使用 CMOY 预设（700Hz, 6.0dB），最接近原实现的默认值。
    pub fn new(sample_rate: f32, _mix: f32, _cutoff_hz: f32, _delay_us: f32) -> Self {
        Crossfeed {
            inner: Bs2b::new(sample_rate.round() as u32, Level::CMOY)
                .expect("bs2b 初始化失败"),
        }
    }

    /// 处理交错立体声缓冲
    pub fn process(&mut self, buf: &mut [f32]) {
        let _ = self.inner.process_interleaved(buf);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crossfeed_leakage() {
        let mut cf = Crossfeed::new(44100.0, 0.3, 700.0, 300.0);
        let frames = 64;
        let mut buf = vec![0.0f32; frames * 2];
        for k in 0..frames {
            buf[2 * k] = 1.0;
        }
        cf.process(&mut buf);
        // 右声道应 > 0（有 crossfeed 泄漏）
        let r_peak = (1..buf.len())
            .step_by(2)
            .map(|i| buf[i].abs())
            .fold(0.0f32, f32::max);
        assert!(r_peak > 0.0, "crossfeed 未产生右声道泄漏: r_peak={r_peak}");
        // 左声道不应被完全削弱
        let l_peak = (0..buf.len())
            .step_by(2)
            .map(|i| buf[i].abs())
            .fold(0.0f32, f32::max);
        assert!(l_peak > 0.5, "crossfeed 过度削弱左声道: {l_peak}");
        // 输出不应为 NaN
        for &s in &buf {
            assert!(!s.is_nan(), "输出含 NaN");
        }
    }
}
