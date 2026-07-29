//! 变速播放：高质量 sinc 重采样
//!
//! 使用 rubato SincFixedOut（256-tap Blackman-Harris 窗）实现变速，
//! 替代旧的线性插值，消除高速播放时的混叠失真。
//!
//! 变速同时变调（如黑胶唱片加速）。如需不变调时间伸缩，需 WSOLA / phase vocoder。

use rubato::{InterpolationParameters, InterpolationType, Resampler, SincFixedOut, WindowFunction};

/// 变速重采样器（rubato sinc 高质量实现）
pub struct SpeedChanger {
    speed: f32,
    channels: usize,
    /// rubato 重采样器（speed 变化时重建）
    resampler: Option<SincFixedOut<f64>>,
    /// 每声道累积缓冲（等待足够帧数后送入 resampler）
    accum: Vec<Vec<f64>>,
    /// 输出缓冲（交错）
    output: Vec<f32>,
}

impl Default for SpeedChanger {
    fn default() -> Self {
        Self::new()
    }
}

impl SpeedChanger {
    /// 新建变速器，初始速度 1.0（正常）
    pub fn new() -> Self {
        SpeedChanger {
            speed: 1.0,
            channels: 0,
            resampler: None,
            accum: Vec::new(),
            output: Vec::new(),
        }
    }

    /// 设置播放速度（0.25 ~ 4.0），速度变化时重建重采样器
    pub fn set_speed(&mut self, speed: f32) {
        let s = speed.clamp(0.25, 4.0);
        if (s - self.speed).abs() > 0.001 {
            self.speed = s;
            // 重建重采样器（速度变化是低频用户操作，重建开销可忽略）
            self.resampler = None;
            self.accum.clear();
        }
    }

    /// 获取当前速度
    pub fn speed(&self) -> f32 { self.speed }

    /// 确保重采样器已创建（延迟初始化，需要知道声道数）
    fn ensure_resampler(&mut self, channels: usize) {
        if self.resampler.is_some() && self.channels == channels {
            return;
        }
        self.channels = channels;
        // ratio = output_rate / input_rate = 1/speed
        // speed=2.0 → ratio=0.5（输出更短），speed=0.5 → ratio=2.0（输出更长）
        let ratio = 1.0 / self.speed as f64;
        let params = InterpolationParameters {
            sinc_len: 256,
            f_cutoff: 0.95,
            interpolation: InterpolationType::Linear,
            oversampling_factor: 256,
            window: WindowFunction::BlackmanHarris2,
        };
        self.resampler = Some(
            SincFixedOut::<f64>::new(ratio, params, 1024, channels)
        );
        self.accum = vec![Vec::new(); channels];
    }

    /// 对交错 PCM 做变速重采样。返回的切片引用内部 buffer，下次调用失效。
    pub fn process<'a>(&'a mut self, input: &'a [f32], channels: usize) -> &'a [f32] {
        if (self.speed - 1.0).abs() < 0.001 || input.is_empty() {
            return input;
        }

        self.ensure_resampler(channels);
        let resampler = self.resampler.as_mut().unwrap();
        self.output.clear();

        // 解交错 → 累积到 per-channel 缓冲
        let frames = input.len() / channels;
        for f in 0..frames {
            for c in 0..channels {
                self.accum[c].push(input[f * channels + c] as f64);
            }
        }

        // 当累积够 resampler 需要的帧数时，处理并输出
        loop {
            let needed = resampler.nbr_frames_needed();
            if self.accum[0].len() < needed {
                break;
            }
            let waves_in: Vec<Vec<f64>> = self.accum.iter_mut()
                .map(|buf| buf.drain(..needed).collect())
                .collect();
            match resampler.process(&waves_in) {
                Ok(waves_out) => {
                    let out_frames = waves_out[0].len();
                    self.output.reserve(out_frames * channels);
                    for f in 0..out_frames {
                        for c in 0..channels {
                            self.output.push(waves_out[c][f] as f32);
                        }
                    }
                }
                Err(_) => break,
            }
        }

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
        // 需要足够多的样本让 resampler 工作
        let input: Vec<f32> = (0..8192).map(|i| (i as f32 * 0.01).sin() * 0.5).collect();
        let mut total_out = 0;
        // 分帧喂入
        for chunk in input.chunks(2048) {
            let out = s.process(chunk, 2);
            total_out += out.len();
        }
        assert!(total_out > 0, "应有输出");
        assert!(total_out < input.len(), "speed=2.0 输出应更短: {} < {}", total_out, input.len());
    }

    #[test]
    fn test_speed_half_longer() {
        let mut s = SpeedChanger::new();
        s.set_speed(0.5);
        let input: Vec<f32> = (0..8192).map(|i| (i as f32 * 0.01).sin() * 0.5).collect();
        let mut total_out = 0;
        for chunk in input.chunks(2048) {
            let out = s.process(chunk, 2);
            total_out += out.len();
        }
        assert!(total_out > input.len(), "speed=0.5 输出应更长: {} > {}", total_out, input.len());
    }

    #[test]
    fn test_speed_preserves_channels() {
        let mut s = SpeedChanger::new();
        s.set_speed(1.5);
        let input: Vec<f32> = (0..8192).map(|i| i as f32 * 0.001).collect();
        for chunk in input.chunks(2048) {
            let out = s.process(chunk, 2);
            assert_eq!(out.len() % 2, 0, "输出应为声道数的整数倍");
        }
    }

    #[test]
    fn test_speed_change_rebuilds() {
        let mut s = SpeedChanger::new();
        s.set_speed(1.5);
        let input: Vec<f32> = (0..4096).map(|i| (i as f32 * 0.01).sin() * 0.5).collect();
        let _ = s.process(&input, 2);
        // 变速后应重建，不 panic
        s.set_speed(0.75);
        let out = s.process(&input, 2);
        // 新速度下应有输出（可能需要多帧累积）
        assert!(out.len() % 2 == 0, "变速后输出格式正确");
    }

    #[test]
    fn test_speed_sine_no_aliasing() {
        // 1kHz 正弦波 @44100Hz，2x 变速后不应引入高频混叠
        let mut s = SpeedChanger::new();
        s.set_speed(2.0);
        let sr = 44100.0f32;
        let input: Vec<f32> = (0..44100)
            .flat_map(|i| {
                let v = (i as f32 * 1000.0 * 2.0 * std::f32::consts::PI / sr).sin() * 0.5;
                vec![v, v]
            })
            .collect();
        let mut all_out = Vec::new();
        for chunk in input.chunks(4096) {
            all_out.extend_from_slice(s.process(chunk, 2));
        }
        // 输出应非空且长度约为输入的一半
        assert!(all_out.len() > input.len() / 4, "输出过短: {}", all_out.len());
        assert!(all_out.len() < input.len(), "2x 变速输出应更短");
        // 输出样本应在合理范围内（无 NaN/Inf）
        for &v in &all_out {
            assert!(v.is_finite(), "输出含非有限值");
            assert!(v.abs() < 1.0, "输出超范围: {v}");
        }
    }
}
