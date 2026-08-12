//! FIR 卷积均衡器
//!
//! 使用 fft-convolver (FFTConvolver) 做分区 FFT 卷积，
//! 加载脉冲响应 (WAV) 文件实现任意频率响应整形。

use fft_convolver::FFTConvolver;

/// FIR 卷积均衡器
///
/// 每声道一个独立的 FFTConvolver 实例。
pub struct ConvolutionEq {
    convolvers: Vec<FFTConvolver<f32>>,
    channels: usize,
    block_size: usize,
    /// 预分配的去交错工作缓冲（避免热路径逐块分配）
    work_in: Vec<f32>,
    /// 预分配的卷积输出缓冲
    work_out: Vec<f32>,
}

impl ConvolutionEq {
    /// 创建空卷积器（bypass 状态）
    pub fn new(channels: usize) -> Self {
        ConvolutionEq {
            convolvers: Vec::new(),
            channels,
            block_size: 256,
            work_in: Vec::new(),
            work_out: Vec::new(),
        }
    }

    /// 从 WAV 文件加载脉冲响应
    ///
    /// - `path`: .wav 文件路径
    /// - `block_size`: FFT 分块大小（推荐 256-1024）
    /// - `expected_sample_rate`: 管线当前采样率；IR 采样率不一致时自动离线重采样
    ///   （不匹配会导致频响静默错位，对房间校正类 IR 是致命的）
    ///
    /// 自动处理 Mono/Stereo IR：Mono IR 应用于所有声道，Stereo IR 逐声道匹配。
    pub fn load_wav(&mut self, path: &str, block_size: usize, expected_sample_rate: u32) -> Result<(), String> {
        let mut reader = hound::WavReader::open(path).map_err(|e| format!("打开 IR 失败: {e}"))?;
        let spec = reader.spec();

        if spec.sample_rate == 0 || spec.channels == 0 {
            return Err("无效的 WAV 规格".into());
        }

        // 读取所有样本，归一化到 [-1, 1]
        let mut raw: Vec<f32> = match spec.sample_format {
            hound::SampleFormat::Float => {
                reader.samples::<f32>().map(|s| s.unwrap_or(0.0)).collect()
            }
            hound::SampleFormat::Int => {
                let max = (1u64 << (spec.bits_per_sample - 1)) as f32;
                reader
                    .samples::<i32>()
                    .map(|s| s.unwrap_or(0) as f32 / max)
                    .collect()
            }
        };

        // IR 采样率与管线不一致 → 逐声道离线重采样（单声道 IR 只重采一次）
        let ir_channels = spec.channels as usize;
        if expected_sample_rate > 0 && (spec.sample_rate as i64 - expected_sample_rate as i64).abs() > 1 {
            let mut resampled = Vec::new();
            for ch in 0..ir_channels {
                let ch_data: Vec<f32> = raw.iter().skip(ch).step_by(ir_channels).copied().collect();
                let rs = crate::dsp::room_correction::resample_ir(&ch_data, spec.sample_rate, expected_sample_rate)?;
                resampled.push(rs);
            }
            // 重新交错（各声道重采样后长度可能差 1~2 样本，取最短对齐）
            let min_len = resampled.iter().map(|c| c.len()).min().unwrap_or(0);
            let mut interleaved = Vec::with_capacity(min_len * ir_channels);
            for i in 0..min_len {
                for c in 0..ir_channels {
                    interleaved.push(resampled[c][i]);
                }
            }
            raw = interleaved;
        }
        let ir_frame_count = raw.len() / ir_channels;

        if ir_frame_count < 16 {
            return Err(format!("IR 过短 ({ir_frame_count} 帧)"));
        }

        // 自适应 block_size：不能超过 IR 长度
        let bs = block_size.min(ir_frame_count).max(16);

        // 为每个输出声道创建独立的 FFTConvolver
        let mut convolvers = Vec::with_capacity(self.channels);
        for ch in 0..self.channels {
            let ir_ch = ch.min(ir_channels - 1);
            let mut ir: Vec<f32> = raw
                .iter()
                .skip(ir_ch)
                .step_by(ir_channels)
                .copied()
                .collect();

            // 补齐到 block_size 的倍数（FFTConvolver 要求）
            let remainder = ir.len() % bs;
            if remainder != 0 {
                ir.resize(ir.len() + bs - remainder, 0.0);
            }

            let mut conv = FFTConvolver::<f32>::default();
            conv.init(bs, &ir)
                .map_err(|e| format!("FFTConvolver init 失败: {e:?}"))?;
            convolvers.push(conv);
        }

        self.convolvers = convolvers;
        self.block_size = bs;
        Ok(())
    }

    /// 处理交错 PCM 缓冲（复用预分配工作缓冲，热路径零分配）
    pub fn process(&mut self, buf: &mut [f32]) {
        if self.convolvers.is_empty() {
            return;
        }
        let ch = self.channels;
        let frames = buf.len() / ch;
        for c in 0..ch.min(self.convolvers.len()) {
            self.work_in.clear();
            self.work_in.extend(buf.iter().skip(c).step_by(ch).copied());
            self.work_out.clear();
            self.work_out.resize(frames, 0.0);
            if self.convolvers[c].process(&self.work_in, &mut self.work_out).is_ok() {
                for (i, &v) in self.work_out.iter().enumerate() {
                    buf[c + i * ch] = v;
                }
            }
        }
    }

    /// 是否已加载 IR（非 bypass 状态）
    pub fn is_active(&self) -> bool {
        !self.convolvers.is_empty()
    }

    /// 卷积引入的固定延迟（样本数）：分区 FFT 卷积的 block_size。
    /// 未加载 IR（bypass）时为 0。用于播放位置补偿
    /// （position_display = 输出位置 - latency_samples / sample_rate）。
    pub fn latency_samples(&self) -> usize {
        if self.convolvers.is_empty() {
            0
        } else {
            self.block_size
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// 生成单声道 32-bit float WAV
    fn write_ir_wav(path: &str, samples: &[f32]) {
        if Path::new(path).exists() { return; }
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 44100,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut w = hound::WavWriter::create(path, spec).unwrap();
        for &s in samples { w.write_sample(s).unwrap(); }
        w.finalize().unwrap();
    }

    #[test]
    fn test_convolver_bypass() {
        let mut conv = ConvolutionEq::new(2);
        assert!(!conv.is_active());
        assert_eq!(conv.latency_samples(), 0, "空卷积器延迟应为 0");
        let mut buf = vec![0.5, -0.3, 0.1, -0.7];
        conv.process(&mut buf);
        assert_eq!(buf, [0.5, -0.3, 0.1, -0.7]);
    }

    #[test]
    #[allow(clippy::approx_constant)] // 3.14 仅作任意非零输入，非圆周率
    fn test_convolver_identity_ir() {
        let path = "/tmp/_test_conv_identity.wav";
        // 16帧 IR：第一帧 1.0，其余 0 → 恒等变换
        let ir: Vec<f32> = {
            let mut v = vec![0.0f32; 16];
            v[0] = 1.0;
            v
        };
        write_ir_wav(path, &ir);

        let mut conv = ConvolutionEq::new(1);
        conv.load_wav(path, 256, 44100).unwrap();
        assert!(conv.is_active());

        let mut buf = vec![0.0f32; 512];
        buf[0] = 3.14; // 任意值
        buf[2] = -2.71;
        conv.process(&mut buf);

        // 卷积结果应等于输入（IR 是单位冲激）
        assert!((buf[0] - 3.14).abs() < 1e-6, "index 0: expected 3.14, got {}", buf[0]);
        assert!((buf[2] - (-2.71)).abs() < 1e-6, "index 2: expected -2.71, got {}", buf[2]);
        for i in ir.len()..buf.len() {
            assert!(buf[i].abs() < 1e-6, "index {i}: expected ~0, got {}", buf[i]);
        }

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn test_convolver_mono_ir_on_stereo() {
        let path = "/tmp/_test_conv_mono_stereo.wav";
        let ir = vec![0.25f32; 16]; // 16帧 DC 脉冲
        write_ir_wav(path, &ir);

        let mut conv = ConvolutionEq::new(2);
        conv.load_wav(path, 256, 44100).unwrap();

        let mut buf = vec![0.0f32; 512];
        buf[0] = 1.0; // 左声道冲激
        buf[1] = 0.5; // 右声道冲激（幅度减半）
        conv.process(&mut buf);

        for i in 0..ir.len() {
            // Mono IR 应同时应用到两个声道
            let diff_l = (buf[i * 2] - 0.25).abs();
            let diff_r = (buf[i * 2 + 1] - 0.125).abs();
            assert!(diff_l < 1e-4, "L index {i}: expected 0.25, got {}", buf[i * 2]);
            assert!(diff_r < 1e-4, "R index {i}: expected 0.125, got {}", buf[i * 2 + 1]);
        }

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn test_load_wav_mismatched_rate_resamples() {
        // 48kHz 的 16 帧 IR，管线 44.1kHz → 应自动重采样（帧数按比例变化）
        let path = "/tmp/_test_conv_resample.wav";
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 48000,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut ir = vec![0.0f32; 1600];
        ir[0] = 1.0;
        let mut w = hound::WavWriter::create(path, spec).unwrap();
        for &s in &ir { w.write_sample(s).unwrap(); }
        w.finalize().unwrap();

        let mut conv = ConvolutionEq::new(1);
        conv.load_wav(path, 256, 44100).unwrap();
        assert!(conv.is_active());

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn test_latency_equals_adaptive_block_size() {
        // 100 帧 IR → block_size 自适应为 min(256, 100).max(16) = 100
        let path = "/tmp/_test_conv_latency.wav";
        let mut ir = vec![0.0f32; 100];
        ir[0] = 1.0;
        write_ir_wav(path, &ir);

        let mut conv = ConvolutionEq::new(2);
        assert_eq!(conv.latency_samples(), 0, "未加载 IR 时延迟应为 0");
        conv.load_wav(path, 256, 44100).unwrap();
        assert_eq!(conv.latency_samples(), 100, "延迟应等于自适应 block_size(100)");

        std::fs::remove_file(path).ok();
    }
}
