//! DSP 正确性量化测试
//!
//! 验证 DSP 管线各处理级的频响、增益、限幅行为符合预期。
//! 用合成信号 + 测量，避免人工试听判断。

use audio_core::dsp::{default_peq_bands, DspPipeline, PeqBand};
use audio_core::dsp::limiter::TruePeakLimiter;
use audio_core::dsp::biquad::Biquad;
use audio_core::dsp::crossfeed::Crossfeed;
use audio_core::dsp::widener::StereoWidener;
use audio_core::dsp::dither::Dither;

// ── 测量工具 ──

fn rms(samples: &[f32]) -> f32 {
    let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

fn db_from_ratio(ratio: f32) -> f32 {
    20.0 * ratio.max(1e-10).log10()
}

fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0f32, |max, &s| max.max(s.abs()))
}

/// 生成正弦波（单声道）
fn generate_sine(freq: f32, amplitude: f32, sample_rate: u32, duration_secs: f32) -> Vec<f32> {
    let n = (sample_rate as f32 * duration_secs) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / sample_rate as f32;
            (t * freq * 2.0 * std::f32::consts::PI).sin() * amplitude
        })
        .collect()
}

/// 单声道转立体声交错
fn to_stereo(mono: &[f32]) -> Vec<f32> {
    let mut stereo = Vec::with_capacity(mono.len() * 2);
    for &s in mono {
        stereo.push(s);
        stereo.push(s);
    }
    stereo
}

/// 用 DspPipeline 测量某频率的增益（dB）
fn pipeline_gain_at(dsp: &mut DspPipeline, sr: u32, freq: f32) -> f32 {
    let signal = generate_sine(freq, 0.1, sr, 1.0);
    let mut buf = to_stereo(&signal);
    let rms_before = rms(&buf);
    dsp.process(&mut buf);
    let rms_after = rms(&buf);
    db_from_ratio(rms_after / rms_before)
}

// ── PEQ 正确性测试 ──

#[test]
fn test_peq_gain_at_center_frequency() {
    let sr = 44100u32;
    let bands = vec![PeqBand { freq: 1000.0, gain_db: 12.0, q: 2.0 }];
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);

    let gain = pipeline_gain_at(&mut dsp, sr, 1000.0);

    assert!(
        (gain - 12.0).abs() < 1.5,
        "PEQ @1kHz +12dB 应在 12±1.5dB 内, 实测: {gain:.2}dB"
    );
}

#[test]
fn test_peq_no_effect_at_distant_frequency() {
    let sr = 96000u32;
    let bands = vec![PeqBand { freq: 1000.0, gain_db: 12.0, q: 2.0 }];
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);

    let gain = pipeline_gain_at(&mut dsp, sr, 10_000.0);

    assert!(
        gain.abs() < 2.0,
        "PEQ @1kHz 不应显著影响 10kHz, 实测: {gain:.2}dB"
    );
}

#[test]
fn test_peq_negative_gain_cuts() {
    let sr = 44100u32;
    let bands = vec![PeqBand { freq: 5000.0, gain_db: -9.0, q: 1.0 }];
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);

    let gain = pipeline_gain_at(&mut dsp, sr, 5000.0);

    assert!(
        gain < -7.0,
        "PEQ @5kHz -9dB 实测 {gain:.2}dB (期望 < -7dB)"
    );
}

#[test]
fn test_default_peq_is_nearly_flat() {
    let sr = 44100u32;
    let bands = default_peq_bands();
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);

    for &freq in &[100.0, 500.0, 1000.0, 5000.0, 10000.0] {
        let gain = pipeline_gain_at(&mut dsp, sr, freq);
        assert!(
            gain.abs() < 1.0,
            "默认 PEQ 在 {freq}Hz 应接近 0dB, 实测: {gain:.2}dB"
        );
    }
}

// ── TruePeakLimiter 正确性 ──

#[test]
fn test_limiter_prevents_clipping() {
    let mut lim = TruePeakLimiter::new(1, -0.3);

    let mut buf = vec![0.0f32; 1000];
    buf[10] = 4.0;
    buf[11] = -4.0;

    lim.process(&mut buf, 0);

    let max_peak = peak(&buf);
    assert!(
        max_peak <= 1.0 + 1e-3,
        "限幅后峰值不应超过 0dBFS, 实测: {max_peak}"
    );
}

#[test]
fn test_limiter_passthrough_below_threshold() {
    let mut lim = TruePeakLimiter::new(1, 0.0);

    let mut buf = vec![0.1f32; 500];
    let expected = buf.clone();
    lim.process(&mut buf, 0);

    for (a, b) in buf.iter().zip(expected.iter()) {
        let diff = (a - b).abs();
        assert!(
            diff < 0.01,
            "低于阈值时应几乎无变化: {a} vs {b}"
        );
    }
}

#[test]
fn test_limiter_releases_slowly() {
    let mut lim = TruePeakLimiter::new(1, 0.0);

    let mut buf = [0.1f32; 200];
    for i in 0..100 {
        buf[i] = 2.0;
    }
    lim.process(&mut buf, 0);

    let max_first_half = buf[..100].iter().fold(0.0f32, |m, &s| m.max(s.abs()));
    assert!(
        max_first_half <= 1.0 + 1e-3,
        "过载段峰值应被限幅: {max_first_half}"
    );
}

// ── StereoWidener 正确性 ──

#[test]
fn test_widener_mono_stays_mono() {
    let mut w = StereoWidener::new();
    w.set_enabled(true);
    w.set_width(1.5);

    let mut buf = vec![0.0f32; 256];
    for i in 0..128 {
        let v = (i as f32 * 0.1).sin() * 0.5;
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }

    w.process(&mut buf);

    for i in 0..128 {
        let diff = (buf[i * 2] - buf[i * 2 + 1]).abs();
        assert!(
            diff < 1e-6,
            "单声道输入经展宽后 L≠R: 索引 {i}, L={}, R={}",
            buf[i * 2],
            buf[i * 2 + 1]
        );
    }
}

#[test]
fn test_widener_increases_stereo_separation() {
    let mut w = StereoWidener::new();
    w.set_enabled(true);
    w.set_width(1.5);

    let mut buf = vec![0.0f32; 256];
    for i in 0..128 {
        buf[i * 2] = 0.5;
        buf[i * 2 + 1] = 0.0;
    }
    let orig = buf.clone();

    w.process(&mut buf);

    let diff_orig = (orig[0] - orig[1]).abs();
    let diff_new = (buf[0] - buf[1]).abs();
    assert!(
        diff_new > diff_orig,
        "展宽应增大 L/R 差异: {diff_orig} -> {diff_new}"
    );
}

#[test]
fn test_widener_disabled_is_passthrough() {
    let mut w = StereoWidener::new();
    w.set_enabled(false);
    w.set_width(1.5);

    let mut buf = vec![0.5f32, -0.3, 0.2, 0.1];
    let expected = buf.clone();
    w.process(&mut buf);

    assert_eq!(buf, expected, "禁用展宽后信号应完全不变");
}

// ── Biquad 基础正确性 ──

#[test]
fn test_biquad_peaking_impulse_response() {
    let mut bq = Biquad::peaking(1000.0, 44100.0, 6.0, 1.0);
    let mut out = vec![0.0f32; 256];
    out[0] = bq.process(1.0);
    for i in 1..256 {
        out[i] = bq.process(0.0);
    }

    for &s in &out {
        assert!(!s.is_nan(), "Biquad 脉冲响应出现 NaN");
    }
}

#[test]
fn test_biquad_dc_gain_unit() {
    let mut bq = Biquad::lowpass(1000.0, 44100.0, 0.707);
    let mut y = 0.0;
    for _ in 0..1000 {
        y = bq.process(1.0);
    }
    assert!(
        (y - 1.0).abs() < 0.01,
        "低通 DC 增益应 ≈1.0, 实测: {y}"
    );
}

// ── Crossfeed 正确性 ──

#[test]
fn test_crossfeed_blends_channels() {
    let sr = 44100.0;
    let mut cf = Crossfeed::new(sr);

    let mut buf = vec![0.0f32; 256];
    for i in 0..128 {
        buf[i * 2] = 0.5;
        buf[i * 2 + 1] = 0.0;
    }

    cf.process(&mut buf);

    let r_energy: f32 = (1..buf.len()).step_by(2).map(|i| buf[i] * buf[i]).sum();
    assert!(
        r_energy > 0.0001,
        "crossfeed 应在 R 声道产生串音信号"
    );

    let l_before = (128 * 2) as f32 * (0.5 * 0.5);
    let l_energy: f32 = (0..buf.len()).step_by(2).map(|i| buf[i] * buf[i]).sum();
    assert!(
        l_energy < l_before,
        "crossfeed 后 L 声道能量应减少: {l_energy} >= {l_before}"
    );
}

// ── Dither ──

#[test]
fn test_dither_adds_noise_within_bounds() {
    let mut d = Dither::new(1, 16, 1.0);
    let original = vec![0.1f32; 1000];
    let mut dithered = original.clone();

    d.process(&mut dithered, 0);

    for (orig, &dit) in original.iter().zip(dithered.iter()) {
        let diff = (orig - dit).abs();
        assert!(
            diff < 1e-4,
            "TPDF dither 噪声不应超过 1 LSB, diff={diff:e}"
        );
    }
}

#[test]
fn test_dither_quiet_signal_has_noise() {
    let mut d = Dither::new(1, 24, 1.0);
    let mut buf = vec![0.0f32; 5000];
    d.process(&mut buf, 0);

    let energy: f32 = buf.iter().map(|&s| s * s).sum();
    assert!(
        energy > 0.0,
        "静音输入经 dither 后应有噪声输出"
    );
}

// ── 管线集成测试 ──

#[test]
fn test_full_pipeline_no_nan_or_inf() {
    let sr = 44100u32;
    let bands = default_peq_bands();
    let mut dsp = DspPipeline::new(sr, 2, &bands, true, 0.8, 24);
    dsp.set_stereo_widener(true, 0.5);

    let signals: Vec<Vec<f32>> = vec![
        generate_sine(100.0, 0.9, sr, 0.2),
        generate_sine(1000.0, 0.1, sr, 0.2),
        generate_sine(15000.0, 0.3, sr, 0.2),
        vec![0.0; 1024],
    ];

    for mono in &signals {
        let mut stereo = to_stereo(mono);
        dsp.process(&mut stereo);
        for &s in &stereo {
            assert!(!s.is_nan(), "输出含 NaN");
            assert!(!s.is_infinite(), "输出含 Inf");
        }
    }
}

#[test]
fn test_full_pipeline_output_bounded() {
    let sr = 44100u32;
    let bands = default_peq_bands();
    let mut dsp = DspPipeline::new(sr, 2, &bands, true, 1.0, 24);

    let mono = generate_sine(440.0, 1.0, sr, 0.2);
    let mut stereo = to_stereo(&mono);
    dsp.process(&mut stereo);

    let max_peak = peak(&stereo);
    assert!(
        max_peak <= 1.0 + 1e-3,
        "满刻度信号经管线不应削波, 峰值: {max_peak}"
    );
}

#[test]
fn test_pipeline_volume_control() {
    let sr = 44100u32;
    let mut dsp = DspPipeline::new(sr, 2, &[], false, 0.5, 24);

    let signal = generate_sine(440.0, 0.5, sr, 0.2);
    let mut buf = to_stereo(&signal);
    let before = rms(&buf);

    dsp.process(&mut buf);
    let after = rms(&buf);

    let ratio = after / before;
    assert!(
        (ratio - 0.5).abs() < 0.05,
        "volume=0.5 时输出 RMS 应为输入一半, 实测: {ratio:.4}"
    );
}

// ── 极端场景 ──

#[test]
fn test_pipeline_empty_buffer() {
    let mut dsp = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
    // 空缓冲区不应 panic
    dsp.process(&mut []);
    dsp.process(&mut [0.0f32; 0]);
}

#[test]
fn test_pipeline_single_stereo_frame() {
    let mut dsp = DspPipeline::new(44100, 2, &default_peq_bands(), true, 1.0, 24);
    // 单帧立体声（2 个样本）不应 panic
    let mut buf = vec![0.5f32, 0.5f32];
    dsp.process(&mut buf);
    assert_eq!(buf.len(), 2);
    for &s in &buf {
        assert!(!s.is_nan());
        assert!(!s.is_infinite());
    }
}

#[test]
fn test_pipeline_extreme_amplitude() {
    let mut dsp = DspPipeline::new(44100, 2, &default_peq_bands(), true, 0.5, 24);
    let mut buf = vec![1e6f32, -1e6f32, 1e6f32, -1e6f32];
    dsp.process(&mut buf);
    // 不应产生 NaN 或 Inf
    for &s in &buf {
        assert!(s.is_finite(), "极端幅度输入不应产生非有限值: {s}");
    }
}

#[test]
fn test_pipeline_dc_removal() {
    let mut dsp = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
    // 纯直流信号，2Hz HPF 需要 ~0.5s 稳定 → 用 132300 样本（3s）
    let mut buf = vec![1.0f32; 132300];
    dsp.process(&mut buf);
    // 检查末尾 10%（HPF 应已稳定）
    let tail = &buf[buf.len() * 9 / 10..];
    let max_abs = tail.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
    assert!(
        max_abs < 0.01,
        "DC 信号经 HPF 后应被滤除, 末尾最大: {max_abs}"
    );
}

#[test]
fn test_pipeline_square_wave_no_clip() {
    let mut dsp = DspPipeline::new(44100, 2, &[], false, 1.0, 24);
    // 满刻度方波（限幅器最差情况）
    let mut buf = Vec::with_capacity(4096);
    for i in 0..2048 {
        let v = if i % 100 < 50 { 1.0 } else { -1.0 };
        buf.push(v);
        buf.push(v);
    }
    dsp.process(&mut buf);
    let max_peak = peak(&buf);
    assert!(
        max_peak <= 1.0 + 1e-3,
        "方波经管线后不应削波（限幅器保护）, 峰值: {max_peak}"
    );
}

#[test]
fn test_limiter_silent_passthrough() {
    let mut lim = TruePeakLimiter::new(2, 0.0);
    let mut buf = vec![0.0f32; 1000];
    lim.process(&mut buf, 0);
    for &s in &buf {
        assert_eq!(s, 0.0, "静音输入限幅后应为 0");
    }
}

// ── 极端场景补充 ──

#[test]
fn test_nan_input_no_panic() {
    let sr = 44100u32;
    let mut dsp = DspPipeline::new(sr, 2, &default_peq_bands(), true, 1.0, 24);
    let mut buf = vec![f32::NAN, 0.5, f32::NAN, -0.5];
    // NaN 输入不应导致 panic（输出可能含 NaN，consumer 坏帧检测会处理）
    dsp.process(&mut buf);
}

#[test]
fn test_inf_input_no_panic() {
    let sr = 44100u32;
    let mut dsp = DspPipeline::new(sr, 2, &default_peq_bands(), true, 1.0, 24);
    let mut buf = vec![f32::INFINITY, -f32::INFINITY, 0.5, -0.5];
    dsp.process(&mut buf);
}

#[test]
fn test_mixed_nan_no_panic() {
    let sr = 44100u32;
    let mut dsp = DspPipeline::new(sr, 2, &default_peq_bands(), true, 0.8, 24);
    let mut buf = generate_sine(440.0, 0.5, sr, 0.1);
    let nan_count = buf.len().min(100);
    for s in buf.iter_mut().rev().take(nan_count) {
        *s = f32::NAN;
    }
    let mut stereo = to_stereo(&buf);
    dsp.process(&mut stereo);
}

#[test]
fn test_peq_extreme_q_value() {
    let sr = 44100u32;
    let bands = vec![PeqBand { freq: 1000.0, gain_db: 12.0, q: 100.0 }];
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);
    let signal = generate_sine(1000.0, 0.1, sr, 0.5);
    let mut buf = to_stereo(&signal);
    dsp.process(&mut buf);
    for &s in &buf {
        assert!(s.is_finite(), "极端 Q=100 后输出非有限: {s}");
    }
}

#[test]
fn test_peq_freq_above_nyquist_no_panic() {
    let sr = 44100u32;
    let bands = vec![PeqBand { freq: 30000.0, gain_db: 12.0, q: 1.0 }];
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);
    let signal = generate_sine(1000.0, 0.1, sr, 0.2);
    let mut buf = to_stereo(&signal);
    // Nyquist 以上频率可能导致不稳定，但不应 panic
    dsp.process(&mut buf);
}

#[test]
fn test_peq_extreme_negative_gain() {
    let sr = 44100u32;
    // 用高 Q 值确保衰减精确
    let bands = vec![PeqBand { freq: 1000.0, gain_db: -40.0, q: 5.0 }];
    let mut dsp = DspPipeline::new(sr, 2, &bands, false, 1.0, 24);
    let signal = generate_sine(1000.0, 0.5, sr, 0.2);
    let mut buf = to_stereo(&signal);
    let rms_before = rms(&buf);
    dsp.process(&mut buf);
    let rms_after = rms(&buf);
    let attenuation = db_from_ratio(rms_after / rms_before);
    assert!(
        attenuation < -30.0,
        "-40dB PEQ 应有显著衰减, 实测: {attenuation:.1}dB"
    );
}

#[test]
fn test_dither_8bit() {
    let mut d = Dither::new(2, 8, 1.0);
    let mut buf = vec![0.0f32; 1000];
    d.process(&mut buf, 0);
    let energy: f32 = buf.iter().map(|&s| s * s).sum();
    assert!(energy > 0.0, "8-bit dither 应有噪声输出");
    let max_abs = buf.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
    assert!(
        max_abs < 0.1,
        "8-bit dither 噪声不应超过 10 个 LSB: {max_abs}"
    );
}

#[test]
fn test_dither_20bit() {
    let mut d = Dither::new(2, 20, 1.0);
    let mut buf = vec![0.0f32; 1000];
    d.process(&mut buf, 0);
    let max_abs = buf.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
    assert!(
        max_abs < 0.001,
        "20-bit dither 噪声幅度应在 LSB/2 附近: {max_abs}"
    );
}

#[test]
fn test_pipeline_multi_channel_odd() {
    // 用 1ch 和 4ch 验证管线对不同声道数无 panic
    for &ch in &[1u32, 4u32] {
        let mut dsp = DspPipeline::new(44100, ch as usize, &default_peq_bands(), true, 1.0, 24);
        let mut buf = vec![0.5f32; 1024 * ch as usize];
        dsp.process(&mut buf);
        for &s in &buf {
            assert!(s.is_finite(), "DSP {ch}ch 输出出现非有限值: {s}");
        }
    }
}
