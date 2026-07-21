//! DSP 管线：串联各滤波器
//!
//! 管线顺序：
//!   DC offset HPF → ReplayGain Pre-amp → 卷积 EQ → IIR PEQ →
//!   Crossfeed → 立体声展宽 → 真峰值限幅 → 音量 → 淡入淡出 → TPDF 抖动
//!
//! ReplayGain（响度归一化增益）在 HPF 后、EQ 前作为 Pre-amp 应用，
//! 确保限幅器看到的是归一化后的信号，不会因 ReplayGain 增益过载。
//! 用户音量（Volume）在限幅器之后，不会破坏限幅器的保护效果。

use crate::dsp::biquad::Biquad;
use crate::dsp::convolver::ConvolutionEq;
use crate::dsp::crossfeed::Crossfeed;
use crate::dsp::dither::Dither;
use crate::dsp::limiter::TruePeakLimiter;
use crate::dsp::widener::StereoWidener;

/// 淡入淡出状态
enum FadeState {
    /// 无淡入淡出
    Idle,
    /// 淡入中
    FadeIn { remaining: u32, total: u32 },
    /// 淡出中
    FadeOut { remaining: u32, total: u32 },
}

impl Default for FadeState {
    fn default() -> Self { FadeState::Idle }
}

/// DSP 管线，按顺序串联：DC HPF → ReplayGain → 卷积 EQ → PEQ → Crossfeed → 展宽 → 限幅 → 音量 → 淡入淡出 → 抖动
pub struct DspPipeline {
    channels: usize,
    /// 每声道一个 DC HPF（独立状态）
    dc_hpf: Vec<Biquad>,
    replaygain_scale: f32,
    conv_eq: Option<ConvolutionEq>,
    /// 每段 PEQ × 每声道（独立状态）
    peq: Vec<Vec<Biquad>>,
    crossfeed: Option<Crossfeed>,
    widener: StereoWidener,
    limiter: TruePeakLimiter,
    dither: Dither,
    volume: f32,
    sample_rate: f32,
    /// 预分配的工作缓冲区（避免热路径分配）
    ch_buf: Vec<f32>,
    /// 淡入淡出状态（防 pause/stop 爆音）
    fade: FadeState,
}

/// 单段 PEQ 参数（ISO 频段）。10 段典型配置见 `default_peq_bands()`。
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct PeqBand {
    /// 中心频率（Hz）
    pub freq: f32,
    /// 增益（dB，范围通常 ±12）
    pub gain_db: f32,
    /// Q 值（影响带宽，典型 0.5~10）
    pub q: f32,
}

impl DspPipeline {
    /// 构造管线。peq_bands: 各段 PEQ 参数；enable_crossfeed: 是否启用串音；
    /// volume: 0~1；bits: 目标输出位深（抖动用）
    pub fn new(
        sample_rate: u32,
        channels: usize,
        peq_bands: &[PeqBand],
        enable_crossfeed: bool,
        volume: f32,
        bits: u32,
    ) -> Self {
        let sr = sample_rate as f32;
        // 每段 PEQ 为每个声道创建独立的 Biquad
        let peq = peq_bands
            .iter()
            .map(|b| {
                (0..channels)
                    .map(|_| Biquad::peaking(b.freq, sr, b.gain_db, b.q))
                    .collect()
            })
            .collect();
        // 每声道一个 DC HPF
        let dc_hpf = (0..channels)
            .map(|_| Biquad::highpass(2.0, sr, 0.707))
            .collect();
        DspPipeline {
            channels,
            dc_hpf,
            replaygain_scale: 1.0,
            conv_eq: None,
            peq,
            crossfeed: if enable_crossfeed && channels >= 2 {
                Some(Crossfeed::new(sr))
            } else {
                None
            },
            widener: StereoWidener::new(),
            limiter: TruePeakLimiter::new(channels, 0.0),
            dither: Dither::new(channels, bits, 1.0),
            volume: volume.clamp(0.0, 1.5),
            sample_rate: sr,
            ch_buf: Vec::new(),
            fade: FadeState::Idle,
        }
    }

    /// 运行时启用/关闭 Crossfeed（串音补偿）
    pub fn set_crossfeed(&mut self, enabled: bool) {
        if enabled && self.channels >= 2 {
            self.crossfeed = Some(Crossfeed::new(self.sample_rate));
        } else {
            self.crossfeed = None;
        }
    }

    /// 处理一帧交错 PCM（长度需为 channels 的整数倍）
    pub fn process(&mut self, buf: &mut [f32]) {
        let ch = self.channels;
        let frames = buf.len() / ch;

        // 1. DC offset HPF（逐声道，每声道独立 Biquad 状态）
        process_biquads_per_channel(&mut self.dc_hpf, &mut self.ch_buf, buf, ch, frames);

        // 1.5 ReplayGain Pre-amp
        if self.replaygain_scale != 1.0 {
            for s in buf.iter_mut() {
                *s *= self.replaygain_scale;
            }
        }

        // 2. FIR 卷积 EQ
        if let Some(conv) = self.conv_eq.as_mut() {
            if conv.is_active() {
                conv.process(buf);
            }
        }

        // 3. IIR PEQ（逐段、逐声道，每声道独立状态）
        for band in self.peq.iter_mut() {
            process_biquads_per_channel(band, &mut self.ch_buf, buf, ch, frames);
        }

        // 4. Crossfeed（立体声）
        if let Some(cf) = self.crossfeed.as_mut() {
            cf.process(buf);
        }

        // 5. 立体声展宽
        self.widener.process(buf);

        // 6. 真峰值限幅（逐声道，复用预分配缓冲区）
        for c in 0..ch {
            self.ch_buf.clear();
            self.ch_buf.extend(buf.iter().skip(c).step_by(ch).copied());
            self.limiter.process(&mut self.ch_buf, c);
            for (i, v) in self.ch_buf.iter().enumerate() {
                buf[c + i * ch] = *v;
            }
        }

        // 7. 音量
        if self.volume != 1.0 {
            for s in buf.iter_mut() {
                *s *= self.volume;
            }
        }

        // 7.5 淡入淡出（防 pause/stop 爆音）
        match &mut self.fade {
            FadeState::FadeIn { ref mut remaining, total } => {
                let total_f = *total as f32;
                for s in buf.iter_mut() {
                    if *remaining > 0 {
                        *s *= 1.0 - *remaining as f32 / total_f;
                        *remaining -= 1;
                    }
                }
                if *remaining == 0 {
                    self.fade = FadeState::Idle;
                }
            }
            FadeState::FadeOut { ref mut remaining, total } => {
                let total_f = *total as f32;
                for s in buf.iter_mut() {
                    if *remaining > 0 {
                        *s *= *remaining as f32 / total_f;
                        *remaining -= 1;
                    } else {
                        *s = 0.0;
                    }
                }
                if *remaining == 0 {
                    self.fade = FadeState::Idle;
                }
            }
            FadeState::Idle => {}
        }

        // 8. TPDF 抖动 / ATH 噪声整形（复用预分配缓冲区）
        for c in 0..ch {
            self.ch_buf.clear();
            self.ch_buf.extend(buf.iter().skip(c).step_by(ch).copied());
            self.dither.process(&mut self.ch_buf, c);
            for (i, v) in self.ch_buf.iter().enumerate() {
                buf[c + i * ch] = *v;
            }
        }
    }

    /// 加载卷积 EQ 的脉冲响应文件
    pub fn load_conv_ir(&mut self, path: &str) -> Result<(), String> {
        let mut conv = ConvolutionEq::new(self.channels);
        conv.load_wav(path, 256)?;
        self.conv_eq = Some(conv);
        Ok(())
    }

    /// 清除卷积 EQ（bypass）
    pub fn clear_conv_ir(&mut self) {
        self.conv_eq = None;
    }

    /// 运行时更新某段 PEQ 参数（所有声道同步更新）
    pub fn set_peq_band(&mut self, index: usize, band: &PeqBand, sample_rate: f32) {
        if index < self.peq.len() {
            let new_bq = Biquad::peaking(band.freq, sample_rate, band.gain_db, band.q);
            for bq in self.peq[index].iter_mut() {
                *bq = new_bq.clone();
            }
        }
    }

    /// 设置 ReplayGain 增益（dB），作为 Pre-amp 在 HPF 后、EQ 前应用
    pub fn set_replaygain_db(&mut self, gain_db: f32) {
        self.replaygain_scale = 10f32.powf(gain_db / 20.0);
    }

    /// 运行时调整音量 (0.0 ~ 1.5)，限幅器之后应用
    pub fn set_volume(&mut self, volume: f32) {
        self.volume = volume.clamp(0.0, 1.5);
    }

    /// 开始淡入（暂停→恢复时消 pop）
    pub fn start_fade_in(&mut self, duration_ms: u32) {
        let samples = (self.sample_rate * duration_ms as f32 / 1000.0) as u32;
        if samples > 0 {
            self.fade = FadeState::FadeIn { remaining: samples, total: samples };
        }
    }

    /// 开始淡出（暂停/停止时消 pop）
    pub fn start_fade_out(&mut self, duration_ms: u32) {
        let samples = (self.sample_rate * duration_ms as f32 / 1000.0) as u32;
        if samples > 0 {
            self.fade = FadeState::FadeOut { remaining: samples, total: samples };
        }
    }

    /// 启用/禁用 ATH 噪声整形（替代 TPDF）
    pub fn set_noise_shaping(&mut self, enabled: bool) {
        self.dither.set_noise_shaping(enabled);
    }

    /// 设置立体声展宽
    pub fn set_stereo_widener(&mut self, enabled: bool, width: f32) {
        self.widener.set_enabled(enabled);
        self.widener.set_width(width);
    }
}

/// 返回默认 31 段 ISO PEQ 频段（所有增益 0 dB，flat 响应）
pub fn default_peq_bands() -> Vec<PeqBand> {
    let freqs = [
        20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0,
        200.0, 250.0, 315.0, 400.0, 500.0, 630.0, 800.0, 1000.0, 1250.0, 1600.0,
        2000.0, 2500.0, 3150.0, 4000.0, 5000.0, 6300.0, 8000.0, 10000.0, 12500.0, 16000.0,
        20000.0,
    ];
    freqs.iter().map(|&f| PeqBand { freq: f, gain_db: 0.0, q: 1.41 }).collect()
}

/// 音效预设名称（10 种 EQ 预设）
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PresetName {
    /// 平坦 / 无增益
    Flat,
    /// 摇滚
    Rock,
    /// 流行
    Pop,
    /// 舞曲
    Dance,
    /// 古典
    Classical,
    /// 柔和
    Soft,
    /// 低频增强
    FullBass,
    /// 高频增强
    FullTreble,
    /// 电子
    Techno,
    /// 人声增强
    Vocals,
}

/// 按预设名称返回对应的 PEQ 频段参数
pub fn preset_bands(name: PresetName) -> Vec<PeqBand> {
    let q = 1.41;
    let freq: [f32; 10] = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

    let gains: [f32; 10] = match name {
        PresetName::Flat => [0.0; 10],
        PresetName::Rock => [-1.2, -1.2, -2.4, -6.5, -7.4, -5.8, -2.6, -0.7, 0.0, 0.0],
        PresetName::Pop => [-5.0, -5.0, -2.4, -1.4, -1.2, -2.2, -4.8, -5.3, -5.3, -5.0],
        PresetName::Dance => [-0.5, -0.5, -1.4, -3.4, -4.3, -4.3, -6.7, -7.2, -7.2, -4.3],
        PresetName::Classical => [-4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -7.2, -7.2, -8.2],
        PresetName::Soft => [-2.4, -2.4, -3.6, -4.8, -5.3, -4.8, -2.6, -1.0, -0.5, 0.5],
        PresetName::FullBass => [-0.5, -0.5, -0.5, -0.5, -1.9, -3.6, -6.0, -7.7, -8.4, -8.6],
        PresetName::FullTreble => [-8.2, -8.2, -8.2, -8.2, -6.0, -3.1, 0.0, 1.9, 1.9, 2.4],
        PresetName::Techno => [-1.2, -1.2, -1.9, -4.1, -6.5, -6.2, -4.1, -1.2, -0.5, -0.7],
        PresetName::Vocals => [-3.0, -3.0, -2.0, -0.5, 1.0, 2.5, 3.0, 1.5, 0.0, 0.0],
    };

    freq.iter().zip(gains.iter()).map(|(&f, &g)| PeqBand { freq: f, gain_db: g, q }).collect()
}

/// 对交错缓冲逐声道应用 Biquad（每声道独立状态，复用预分配缓冲区）
fn process_biquads_per_channel(
    bqs: &mut [Biquad],
    ch_buf: &mut Vec<f32>,
    buf: &mut [f32],
    ch: usize,
    frames: usize,
) {
    if ch <= 1 {
        bqs[0].process_slice(buf);
        return;
    }
    for c in 0..ch {
        ch_buf.clear();
        ch_buf.reserve(frames);
        for i in 0..frames {
            ch_buf.push(buf[c + i * ch]);
        }
        bqs[c].process_slice(ch_buf);
        for (i, &v) in ch_buf.iter().enumerate() {
            buf[c + i * ch] = v;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pipeline_no_clip_default() {
        let bands = [PeqBand {
            freq: 1000.0,
            gain_db: 0.0,
            q: 1.0,
        }];
        let mut p = DspPipeline::new(44100, 2, &bands, false, 1.0, 24);
        let mut buf = vec![0.9f32; 2048];
        for (i, s) in buf.iter_mut().enumerate() {
            *s = if i % 2 == 0 { 0.9 } else { -0.9 };
        }
        p.process(&mut buf);
        for &s in &buf {
            assert!(s.abs() <= 1.0 + 1e-2, "管线输出超 0 dBFS: {s}");
        }
    }

    #[test]
    fn test_pipeline_volume_applies() {
        let bands = [];
        let mut p = DspPipeline::new(44100, 2, &bands, false, 0.5, 24);
        let mut buf = vec![1.0f32, -1.0, 1.0, -1.0];
        p.process(&mut buf);
        assert!(
            buf[0].abs() < 0.55 && buf[0].abs() > 0.45,
            "音量未生效: {}",
            buf[0]
        );
    }

    #[test]
    fn test_preset_bands_structure() {
        for name in &[PresetName::Flat, PresetName::Rock, PresetName::Pop,
                      PresetName::Dance, PresetName::Classical, PresetName::Soft,
                      PresetName::FullBass, PresetName::FullTreble, PresetName::Techno,
                      PresetName::Vocals] {
            let bands = preset_bands(*name);
            assert_eq!(bands.len(), 10, "预设 {name:?} 应返回 10 段");
            for (i, b) in bands.iter().enumerate() {
                assert!(b.freq > 0.0, "预设 {name:?} 第{i}段 freq 无效: {}", b.freq);
                assert!(b.q > 0.0, "预设 {name:?} 第{i}段 q 无效: {}", b.q);
            }
        }
    }

    #[test]
    fn test_default_eq_bands_structure() {
        let bands = default_peq_bands();
        assert_eq!(bands.len(), 31);
        for (i, b) in bands.iter().enumerate() {
            assert!(b.freq > 0.0, "第{i}段 freq 无效: {}", b.freq);
            assert!(b.q > 0.0, "第{i}段 q 无效: {}", b.q);
        }
    }

    /// 验证左右声道 Biquad 状态独立——连续两帧 DC 输入，左右应各自收敛
    #[test]
    fn test_biquad_per_channel_state_independence() {
        let bands = [PeqBand { freq: 1000.0, gain_db: 6.0, q: 1.0 }];
        let mut p = DspPipeline::new(44100, 2, &bands, false, 1.0, 24);
        // 第一帧：左声道 0.5，右声道 0.0
        let mut buf1: Vec<f32> = (0..512).flat_map(|_| [0.5f32, 0.0]).collect();
        p.process(&mut buf1);
        // 第二帧：左声道 0.5，右声道 0.0
        let mut buf2: Vec<f32> = (0..512).flat_map(|_| [0.5f32, 0.0]).collect();
        p.process(&mut buf2);
        // 左声道第二帧输出应与第一帧不同（滤波器状态在演进）
        // 如果状态丢失（每帧重置），两帧输出会完全相同
        let left1: f32 = buf1.iter().step_by(2).take(10).sum();
        let left2: f32 = buf2.iter().step_by(2).take(10).sum();
        assert!(
            (left1 - left2).abs() > 1e-6,
            "左声道 Biquad 状态未延续：两帧输出几乎相同 ({left1} vs {left2})"
        );
    }

    // ── ReplayGain Pre-amp ──

    #[test]
    fn test_replaygain_scale_factor() {
        let mut p = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
        p.set_replaygain_db(6.0);
        let mut buf = vec![0.5f32, -0.3, 0.2, -0.1];
        p.process(&mut buf);
        for &s in &buf {
            assert!(s.abs() <= 1.0 + 1e-2, "ReplayGain +6dB 后限幅器应防止过冲: {s}");
        }
        let avg = buf.iter().map(|x| x.abs()).sum::<f32>() / buf.len() as f32;
        assert!(avg > 0.4, "ReplayGain +6dB 后平均幅值应明显增大: {avg}");
    }

    #[test]
    fn test_replaygain_negative_reduces_amplitude() {
        let mut p = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
        p.set_replaygain_db(-12.0);
        let mut buf = vec![0.8f32; 1024];
        p.process(&mut buf);
        let peak = buf.iter().map(|x| x.abs()).fold(0.0f32, f32::max);
        assert!(peak < 0.3, "ReplayGain -12dB 后峰值应明显降低: {peak}");
        assert!(peak > 0.1, "ReplayGain -12dB 后应仍有信号: {peak}");
    }

    #[test]
    fn test_replaygain_zero_is_noop() {
        let mut p = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
        p.set_replaygain_db(0.0);
        let input = vec![0.3f32, -0.2, 0.1, -0.4];
        let mut buf = input.clone();
        p.process(&mut buf);
        assert!((buf[0] - input[0]).abs() < 0.1, "0dB ReplayGain 应接近无变化: {}", buf[0]);
    }

    #[test]
    fn test_replaygain_set_replaygain_engine() {
        let (handle, _rx) = crate::engine::EngineHandle::start();
        handle.set_replaygain_gain_db(6.0);
        handle.set_replaygain_gain_db(-3.0);
        handle.set_replaygain_gain_db(0.0);
        drop(handle);
    }

    // ── DSP 管线延迟基准测试 ──
    // 目标：确保 DSP 处理速度远快于实时，避免 consumer 线程堆积导致 ringbuf underrun。

    #[test]
    fn test_dsp_pipeline_latency() {
        // 最坏情况配置：31段PEQ + crossfeed + widener + limiter + dither
        let bands = crate::dsp::default_peq_bands();
        let mut p = DspPipeline::new(48000, 2, &bands, true, 1.0, 24);
        p.set_stereo_widener(true, 0.5);

        let frame_size = 1024; // 每帧样本数（交错立体声）
        let total_frames = 100;
        let mut buf = vec![0.0f32; frame_size];
        // 填充白噪声（避免 flat DC 信号导致管线旁路优化）
        for i in 0..frame_size {
            buf[i] = (i as f32 * 0.1).sin() * 0.5;
        }

        let start = std::time::Instant::now();
        for _ in 0..total_frames {
            p.process(&mut buf);
        }
        let elapsed = start.elapsed();

        // 每帧音频时长（1024 samples @48000Hz 立体声 = 1024/96000 ≈ 10.67ms）
        let frame_audio_ms = frame_size as f64 / (48000.0 * 2.0) * 1000.0;
        let avg_process_us = elapsed.as_micros() as f64 / total_frames as f64;

        // 处理时间必须远小于音频时长（安全阈值：不超过音频时长的 50%）
        let threshold_us = frame_audio_ms * 1000.0 * 0.5;
        assert!(
            avg_process_us < threshold_us,
            "DSP 处理过慢: avg {avg_process_us:.0}µs/帧, 音频时长 {frame_audio_ms:.1}ms/帧, 阈值 {threshold_us:.0}µs"
        );
        eprintln!("DSP benchmark: {total_frames}帧, avg {avg_process_us:.0}µs/帧 ({frame_audio_ms:.1}ms 音频/帧), 实时比 {:.1}x",
            frame_audio_ms * 1000.0 / avg_process_us);
    }

    // ── 淡入淡出测试 ──

    #[test]
    fn test_fade_in_ramp() {
        let mut p = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
        p.start_fade_in(5); // 5ms ≈ 220 samples @44100
        let mut buf = vec![1.0f32; 256]; // 128 stereo frames
        p.process(&mut buf);
        // 前几个样本应接近 0，最后一个应接近 1.0
        assert!(buf[0] < 0.3, "fade in 首样本应小: {}", buf[0]);
        assert!(buf[buf.len() - 1] > 0.5, "fade in 末样本应大: {}", buf[buf.len() - 1]);
        // 处理完后 fade 应回到 Idle
        assert!(matches!(p.fade, FadeState::Idle), "fade 完成后应 Idle");
    }

    #[test]
    fn test_fade_out_ramp() {
        let mut p = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
        p.start_fade_out(5);
        let mut buf = vec![1.0f32; 256];
        p.process(&mut buf);
        // 前几个样本应接近 1.0，最后一个应接近 0
        assert!(buf[0] > 0.5, "fade out 首样本应大: {}", buf[0]);
        assert!(buf[buf.len() - 1].abs() < 0.3, "fade out 末样本应小: {}", buf[buf.len() - 1]);
        assert!(matches!(p.fade, FadeState::Idle), "fade 完成后应 Idle");
    }

    #[test]
    fn test_fade_noop_when_idle() {
        let mut p = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
        let mut buf = vec![0.5f32; 100];
        let expected = buf.clone();
        p.process(&mut buf);
        // idle 时不应改变信号（信号经 PEQ/limiter 可能有微小变化，但数量级不变）
        for (a, b) in buf.iter().zip(expected.iter()) {
            let diff = (a - b).abs();
            assert!(diff < 0.1, "idle fade 应接近无变化: {a} vs {b}");
        }
    }

    // ── 信号连续性测试 ──
    // 验证管线不会在无中断的输入信号中插入零样本或大幅跳变。

    #[test]
    fn test_pipeline_signal_continuity() {
        let bands = crate::dsp::default_peq_bands();
        let mut p = DspPipeline::new(44100, 2, &bands, true, 1.0, 24);
        p.set_stereo_widener(true, 0.5);

        // 生成连续正弦波（无零值、无间断）
        let len = 4410; // 0.1秒 @44100Hz 立体声 → 8820 samples
        let mut buf = Vec::with_capacity(len * 2);
        for i in 0..len {
            let s = (i as f32 * 440.0 * 2.0 * std::f32::consts::PI / 44100.0).sin() * 0.5;
            buf.push(s);
            buf.push(s);
        }

        p.process(&mut buf);

        // 检查 1: 没有零值样本（输入非零，DC HPF + Biquad 后不应全零）
        let zero_count = buf.iter().filter(|&&s| s.abs() < 1e-10).count();
        assert!(
            zero_count < buf.len() / 100,
            "输出中出现过多接近零的样本: {}/{}", zero_count, buf.len()
        );

        // 检查 2: 信号连续（相邻样本间无 >0.5 的跳变，表明无 fill(0) 插入）
        let mut max_jump = 0.0f32;
        for i in 1..buf.len() {
            let jump = (buf[i] - buf[i - 1]).abs();
            if jump > max_jump { max_jump = jump; }
        }
        assert!(
            max_jump < 0.5,
            "信号连续性异常：相邻样本最大跳变 {max_jump}, 可能存在 fill(0) 或 gain 跳变"
        );
    }
}
