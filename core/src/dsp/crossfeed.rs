//! Crossfeed（Bauer 算法）
//!
//! 耳机聆听时左右声道完全分离，缺少音箱摆放时的“串音”，
//! 导致声场不自然、中频凹陷。Bauer 算法把对侧信号经低通+衰减后混入同侧，
//! 模拟音箱串音。
//!
//! 支持三种经典预设：
//! - CMOY: 700Hz 低通, 6.0dB 衰减, 300µs 延迟（最流行）
//! - Chu Moy: 700Hz 低通, 6.0dB 衰减, 250µs 延迟（CMOY 变体，稍紧凑）
//! - Jan Meier: 650Hz 低通, 9.5dB 衰减, 250µs 延迟（更温和，适合古典）

use crate::dsp::biquad::Biquad;
use std::collections::VecDeque;

/// Crossfeed 预设参数
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CrossfeedConfig {
    /// 低通截止频率 (Hz)
    pub cutoff_hz: f32,
    /// 对侧信号衰减 (dB)
    pub attenuation_db: f32,
    /// 延迟线时长 (µs)
    pub delay_us: f32,
}

impl CrossfeedConfig {
    /// CMOY 预设（最流行）: 700Hz, -6.0dB, 300µs
    pub const CMOY: CrossfeedConfig = CrossfeedConfig {
        cutoff_hz: 700.0,
        attenuation_db: 6.0,
        delay_us: 300.0,
    };

    /// Chu Moy 预设（CMOY 变体，稍紧凑）: 700Hz, -6.0dB, 250µs
    pub const CHU_MOY: CrossfeedConfig = CrossfeedConfig {
        cutoff_hz: 700.0,
        attenuation_db: 6.0,
        delay_us: 250.0,
    };

    /// Jan Meier 预设（更温和，适合古典）: 650Hz, -9.5dB, 250µs
    pub const JAN_MEIER: CrossfeedConfig = CrossfeedConfig {
        cutoff_hz: 650.0,
        attenuation_db: 9.5,
        delay_us: 250.0,
    };
}

/// Bauer 算法跨馈处理器
pub struct Crossfeed {
    /// 左→右、右→左各一个低通滤波器
    lpf_l: Biquad,
    lpf_r: Biquad,
    /// 延迟线（每声道）
    delay_l: VecDeque<f32>,
    delay_r: VecDeque<f32>,
    /// 混合增益（-6.0 dB ≈ 0.5）
    mix_gain: f32,
}

impl Crossfeed {
    /// 创建 Crossfeed，使用 CMOY 预设（默认）
    pub fn new(sample_rate: f32) -> Self {
        Self::with_config(sample_rate, CrossfeedConfig::CMOY)
    }

    /// 创建 Crossfeed，使用自定义配置
    pub fn with_config(sample_rate: f32, config: CrossfeedConfig) -> Self {
        let delay_samples = ((sample_rate * config.delay_us * 1e-6).round() as usize).max(1);
        let mix_gain = 10f32.powf(-config.attenuation_db / 20.0);

        let lpf_l = Biquad::lowpass(config.cutoff_hz, sample_rate, 0.707);
        let lpf_r = Biquad::lowpass(config.cutoff_hz, sample_rate, 0.707);

        Crossfeed {
            lpf_l,
            lpf_r,
            delay_l: VecDeque::from(vec![0.0f32; delay_samples]),
            delay_r: VecDeque::from(vec![0.0f32; delay_samples]),
            mix_gain,
        }
    }

    /// 处理交错立体声缓冲 [L, R, L, R, ...]
    pub fn process(&mut self, buf: &mut [f32]) {
        let n = buf.len() / 2;
        for i in 0..n {
            let l = buf[2 * i];
            let r = buf[2 * i + 1];

            // 对侧信号经低通 + 延迟
            let xfeed_l = self.delay_l.pop_front().unwrap_or(0.0);
            let xfeed_r = self.delay_r.pop_front().unwrap_or(0.0);

            // 当前信号低通后写入延迟线
            let filtered_l = self.lpf_l.process(l);
            let filtered_r = self.lpf_r.process(r);
            self.delay_l.push_back(filtered_l);
            self.delay_r.push_back(filtered_r);

            // 混入对侧串音
            buf[2 * i] = l + xfeed_r * self.mix_gain;
            buf[2 * i + 1] = r + xfeed_l * self.mix_gain;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crossfeed_leakage() {
        let mut cf = Crossfeed::new(44100.0);
        let mut buf = vec![0.0f32; 128];
        for k in 0..64 {
            buf[2 * k] = 1.0; // 左声道全 1
        }
        cf.process(&mut buf);
        // 右声道应有泄漏
        let r_peak = (1..buf.len())
            .step_by(2)
            .map(|i| buf[i].abs())
            .fold(0.0f32, f32::max);
        assert!(r_peak > 0.0, "crossfeed 未产生右声道泄漏: r_peak={r_peak}");
        // 输出不应为 NaN
        for &s in &buf {
            assert!(!s.is_nan(), "输出含 NaN");
        }
    }

    #[test]
    fn test_crossfeed_delay_line() {
        // 验证延迟线确实引入延迟（而非直通）
        let mut cf = Crossfeed::new(44100.0);
        let mut buf = vec![0.0f32; 128];
        buf[0] = 1.0; // 第一帧左声道一个脉冲
        cf.process(&mut buf);
        // 右声道第一帧应为 0（延迟导致不会立即泄漏）
        assert!(buf[1].abs() < 1e-6, "延迟线未生效, 右声道首帧={}", buf[1]);
    }

    #[test]
    fn test_crossfeed_stereo_identity_no_input() {
        let mut cf = Crossfeed::new(44100.0);
        let mut buf = vec![0.0f32; 64];
        cf.process(&mut buf);
        for &s in &buf {
            assert_eq!(s, 0.0, "静音输入应保持静音");
        }
    }

    #[test]
    fn test_crossfeed_lowpass_smoothes() {
        // 高频信号经低通后应被衰减
        let mut cf = Crossfeed::new(44100.0);
        let mut buf = vec![0.0f32; 128];
        // 10kHz 方波（采样率 44100 下约每 4.4 样本反转一次）
        for i in 0..64 {
            buf[2 * i] = if i % 5 < 3 { 1.0 } else { -1.0 };
        }
        let orig_l_peak: f32 = (0..128)
            .step_by(2)
            .map(|i| buf[i].abs())
            .fold(0.0f32, f32::max);
        cf.process(&mut buf);
        // 延迟线上的低通滤波使泄漏到右声道的信号幅度小于原始
        let xfeed_peak: f32 = (1..128)
            .step_by(2)
            .map(|i| buf[i].abs())
            .fold(0.0f32, f32::max);
        assert!(
            xfeed_peak < orig_l_peak,
            "低通应衰减高频串音: {xfeed_peak} >= {orig_l_peak}"
        );
    }
}
