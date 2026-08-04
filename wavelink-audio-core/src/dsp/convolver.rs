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
}

impl ConvolutionEq {
    /// 创建空卷积器（bypass 状态）
    pub fn new(channels: usize) -> Self {
        ConvolutionEq {
            convolvers: Vec::new(),
            channels,
            block_size: 256,
        }
    }

    /// 从 WAV 文件加载脉冲响应
    ///
    /// - `path`: .wav 文件路径
    /// - `block_size`: FFT 分块大小（推荐 256-1024）
    ///
    /// 自动处理 Mono/Stereo IR：Mono IR 应用于所有声道，Stereo IR 逐声道匹配。
    pub fn load_wav(&mut self, path: &str, block_size: usize) -> Result<(), String> {
        let mut reader = hound::WavReader::open(path).map_err(|e| format!("打开 IR 失败: {e}"))?;
        let spec = reader.spec();

        if spec.sample_rate == 0 || spec.channels == 0 {
            return Err("无效的 WAV 规格".into());
        }

        // 读取所有样本，归一化到 [-1, 1]
        let raw: Vec<f32> = match spec.sample_format {
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

        let ir_channels = spec.channels as usize;
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

    /// 处理交错 PCM 缓冲
    pub fn process(&mut self, buf: &mut [f32]) {
        if self.convolvers.is_empty() {
            return;
        }
        let ch = self.channels;
        for c in 0..ch.min(self.convolvers.len()) {
            let ch_buf: Vec<f32> = buf.iter().skip(c).step_by(ch).copied().collect();
            let mut out_buf = vec![0.0f32; ch_buf.len()];
            if self.convolvers[c].process(&ch_buf, &mut out_buf).is_ok() {
                for (i, v) in out_buf.into_iter().enumerate() {
                    buf[c + i * ch] = v;
                }
            }
        }
    }

    /// 是否已加载 IR（非 bypass 状态）
    pub fn is_active(&self) -> bool {
        !self.convolvers.is_empty()
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
        conv.load_wav(path, 256).unwrap();
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
        conv.load_wav(path, 256).unwrap();

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
}
