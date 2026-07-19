//! 立体声展宽 (Mid/Side 处理)
//!
//! Mid/Side 解码: M = L + R, S = L - R
//! 展宽: new_L = M + S * width, new_R = M - S * width
//! width=1.0 → 原始, width=0.0 → 单声道, width>1.0 → 展宽

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
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_width(&mut self, width: f32) {
        self.width = width.max(0.0);
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn enabled(&self) -> bool { self.enabled }
    pub fn width(&self) -> f32 { self.width }

    /// 处理交错立体声缓冲 [L, R, L, R, ...]
    pub fn process(&mut self, buf: &mut [f32]) {
        if !self.enabled || self.width == 1.0 { return; }
        let n = buf.len();
        let mut i = 0;
        while i + 1 < n {
            let l = buf[i];
            let r = buf[i + 1];
            let m = l + r;
            let s = l - r;
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
}
