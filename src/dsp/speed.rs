//! 变速播放：线性插值重采样
//!
//! 在 DSP 管线输出后进行线性插值重采样，实现变调变速。
//! 如需保持音调不变（时间伸缩），后续可替换为 WSOLA / phase vocoder。

/// 变速重采样器
pub struct SpeedChanger {
    speed: f32,
    phase: f32,
    leftover: Vec<f32>,
    output: Vec<f32>,
    combined: Vec<f32>,
}

impl SpeedChanger {
    /// 新建变速器，初始速度 1.0（正常）
    pub fn new() -> Self {
        SpeedChanger { speed: 1.0, phase: 0.0, leftover: Vec::new(), output: Vec::new(), combined: Vec::new() }
    }

    /// 设置播放速度（0.25 ~ 4.0）
    pub fn set_speed(&mut self, speed: f32) {
        self.speed = speed.clamp(0.25, 4.0);
    }

    /// 获取当前速度
    pub fn speed(&self) -> f32 { self.speed }

    /// 对交错 PCM 做变速重采样。返回的切片引用内部 buffer，下次调用失效。
    pub fn process<'a>(&'a mut self, input: &'a [f32], channels: usize) -> &'a [f32] {
        if (self.speed - 1.0).abs() < 0.001 || input.is_empty() {
            return input;
        }
        self.output.clear();

        // 拼接残留+输入到 combined
        self.combined.clear();
        if !self.leftover.is_empty() {
            self.combined.extend_from_slice(&self.leftover);
            self.leftover.clear();
        }
        self.combined.extend_from_slice(input);
        let data = &self.combined;

        let ch = channels;
        let frames = data.len() / ch;
        if frames == 0 { return &[]; }

        self.output.reserve((frames as f32 / self.speed).ceil() as usize * ch + 4);

        while self.phase as usize + 1 < frames {
            let idx = self.phase as usize;
            let frac = self.phase.fract();
            for c in 0..ch {
                let a = data[idx * ch + c];
                let b = data[(idx + 1) * ch + c];
                self.output.push(a + (b - a) * frac);
            }
            self.phase += self.speed;
        }

        // 保存残留样本供下次使用
        let consumed_frames = self.phase as usize;
        if consumed_frames < frames {
            self.leftover.extend_from_slice(&data[consumed_frames * ch..]);
        }
        self.phase -= consumed_frames as f32;
        if self.phase < 0.0 { self.phase = 0.0; }

        &self.output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_speed_unity_passthrough() {
        let mut s = SpeedChanger::new();
        let input = vec![0.5f32, -0.3, 0.2, -0.1];
        let out = s.process(&input, 2);
        assert_eq!(out.len(), input.len(), "speed=1.0 应透传");
        for (&a, &b) in out.iter().zip(input.iter()) {
            assert!((a - b).abs() < 1e-6);
        }
    }

    #[test]
    fn test_speed_double_shorter() {
        let mut s = SpeedChanger::new();
        s.set_speed(2.0);
        let input: Vec<f32> = (0..200).map(|i| (i as f32 * 0.1).sin()).collect();
        let out = s.process(&input, 2);
        assert!(out.len() < input.len(), "speed=2.0 输出应更短: {} < {}", out.len(), input.len());
        assert!(out.len() as f32 > input.len() as f32 / 2.0 * 0.5, "约一半长度: {}", out.len());
    }

    #[test]
    fn test_speed_half_longer() {
        let mut s = SpeedChanger::new();
        s.set_speed(0.5);
        let input: Vec<f32> = (0..100).map(|i| (i as f32 * 0.1).sin()).collect();
        let out = s.process(&input, 2);
        assert!(out.len() > input.len(), "speed=0.5 输出应更长: {} > {}", out.len(), input.len());
    }

    #[test]
    fn test_speed_preserves_channels() {
        let mut s = SpeedChanger::new();
        s.set_speed(1.5);
        let input: Vec<f32> = (0..80).map(|i| i as f32).collect();
        let out = s.process(&input, 2);
        assert_eq!(out.len() % 2, 0, "输出应为声道数的整数倍");
    }

    #[test]
    fn test_speed_leftover_continuity() {
        let mut s = SpeedChanger::new();
        s.set_speed(1.3);
        let f1: Vec<f32> = (0..40).map(|i| i as f32).collect();
        let f2: Vec<f32> = (40..80).map(|i| i as f32).collect();
        let out1 = s.process(&f1, 2).to_vec();
        let out2 = s.process(&f2, 2).to_vec();
        let mut combined = out1;
        combined.extend_from_slice(&out2);

        let mut s2 = SpeedChanger::new();
        s2.set_speed(1.3);
        let input: Vec<f32> = (0..80).map(|i| i as f32).collect();
        let once = s2.process(&input, 2);

        let max_diff = combined.iter().zip(once.iter()).map(|(a, b)| (a - b).abs()).fold(0.0f32, f32::max);
        assert!(max_diff < 0.01, "分帧处理应与一次处理接近, max_diff={max_diff}");
    }
}
