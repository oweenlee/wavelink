//! 立体声展宽 (Mid/Side 处理)
//!
//! Mid/Side 解码: M = (L + R)/2, S = (L - R)/2
//! 展宽: new_L = M + S * width, new_R = M - S * width
//! width=1.0 → 原始, width=0.0 → 单声道, width>1.0 → 展宽
//! （M/S 必须带 1/2 归一，否则 width≠1 时电平翻倍 +6dB）

/// 立体声展宽处理器（Mid/Side 处理）。
/// width=1.0 → 原始, width=0.0 → 单声道, width>1.0 → 展宽
pub struct StereoWidener {
    width: f32,
    enabled: bool,
}

impl Default for StereoWidener {
    fn default() -> Self {
        Self { width: 1.0, enabled: false }
    }
}

impl StereoWidener {
    /// 创建默认关闭的展宽器
    pub fn new() -> Self {
        Self::default()
    }

    /// 设置展宽系数（0.0 = 单声道, 1.0 = 原始, >1.0 = 展宽）
    pub fn set_width(&mut self, width: f32) {
        self.width = width.max(0.0);
    }

    /// 启用/禁用展宽
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    /// 是否已启用
    pub fn enabled(&self) -> bool { self.enabled }
    /// 当前展宽系数
    pub fn width(&self) -> f32 { self.width }

    /// 处理交错立体声缓冲 [L, R, L, R, ...]
    pub fn process(&mut self, buf: &mut [f32]) {
        if !self.enabled || self.width == 1.0 { return; }
        let n = buf.len();
        let mut i = 0;
        while i + 1 < n {
            let l = buf[i];
            let r = buf[i + 1];
            let m = (l + r) * 0.5;
            let s = (l - r) * 0.5;
            buf[i] = m + s * self.width;
            buf[i + 1] = m - s * self.width;
            i += 2;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_widener_identity_at_width_1() {
        let mut w = StereoWidener::new();
        w.set_enabled(true);
        w.set_width(1.0);
        let mut buf = vec![0.5, -0.3, 0.2, 0.1];
        let orig = buf.clone();
        w.process(&mut buf);
        assert_eq!(buf, orig, "width=1 时应不变");
    }

    #[test]
    fn test_widener_mono_at_width_0() {
        let mut w = StereoWidener::new();
        w.set_enabled(true);
        w.set_width(0.0);
        let mut buf = vec![0.5, -0.3, 0.2, 0.1];
        w.process(&mut buf);
        // width=0 → M+S*0 = M, M-S*0 = M → 两侧变为同一值
        assert!((buf[0] - buf[1]).abs() < 1e-6, "width=0 应变为单声道");
        assert!((buf[2] - buf[3]).abs() < 1e-6, "width=0 应变为单声道");
    }

    #[test]
    fn test_widener_wider_increases_diff() {
        let mut w = StereoWidener::new();
        w.set_enabled(true);
        w.set_width(1.5);
        let mut buf = vec![0.5, -0.3, 0.2, 0.1];
        let orig = buf.clone();
        w.process(&mut buf);
        // 展宽后左右差异应增大
        let diff_orig = (orig[0] - orig[1]).abs();
        let diff_new = (buf[0] - buf[1]).abs();
        assert!(diff_new > diff_orig, "展宽应增大差异: {diff_orig} -> {diff_new}");
    }

    #[test]
    fn test_widener_disabled_by_default() {
        let w = StereoWidener::new();
        assert!(!w.enabled(), "默认应关闭");
        assert!((w.width() - 1.0).abs() < 1e-6, "默认 width 应为 1.0");
    }

    /// 纯 Mid 信号（L=R）经任意 width 处理不应改变电平（回归：M/S 缺 1/2 归一
    /// 会让 width≠1 时电平翻倍 +6dB）
    #[test]
    fn test_widener_mid_preserved_at_any_width() {
        for width in [0.0f32, 0.5, 1.5, 2.0] {
            let mut w = StereoWidener::new();
            w.set_enabled(true);
            w.set_width(width);
            let mut buf = vec![0.4, 0.4, -0.2, -0.2];
            w.process(&mut buf);
            for (i, &s) in buf.iter().enumerate() {
                let expect = if i < 2 { 0.4 } else { -0.2 };
                assert!(
                    (s - expect).abs() < 1e-6,
                    "width={width} 时纯 Mid 信号电平被篡改: {s} != {expect}"
                );
            }
        }
    }
}
