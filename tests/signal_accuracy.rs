//! 端到端信号精度测试
//!
//! 验证 解码 → 重采样 → 声道混音 → DSP 全链路的信号正确性。
//! 用合成信号 + FFT 测量，确保音频数据在管线中不被损坏。

mod common;

use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Duration;

use audio_core::decoder::{decode_to_memory, Decoder};
use audio_core::dsp::{DspPipeline, PeqBand};
use realfft::num_complex::Complex;
use realfft::RealFftPlanner;

// ── 测量工具 ──

/// 用 FFT 测量信号中指定频率的幅度（线性）
fn measure_amplitude_at(samples: &[f32], freq: f32, sample_rate: u32) -> f32 {
    let fft_size = samples.len().min(65536).next_power_of_two();
    let mut planner = RealFftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(fft_size);

    // 取前 fft_size 个样本，加 Hann 窗
    let mut input = vec![0.0f32; fft_size];
    for i in 0..fft_size {
        let s = if i < samples.len() { samples[i] } else { 0.0 };
        let w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / (fft_size - 1) as f32).cos());
        input[i] = s * w;
    }

    let mut output = vec![Complex::new(0.0f32, 0.0f32); fft_size / 2 + 1];
    fft.process(&mut input, &mut output).unwrap();

    // 找目标频率对应的 bin
    let bin = (freq * fft_size as f32 / sample_rate as f32).round() as usize;
    // 取 bin ± 2 范围内的峰值（频谱泄漏）
    let start = bin.saturating_sub(2);
    let end = (bin + 3).min(output.len());
    let mut max_mag = 0.0f32;
    for b in start..end {
        let mag = output[b].norm();
        if mag > max_mag { max_mag = mag; }
    }
    // Hann 窗补偿：相干增益 0.5，单边谱 ×2
    // amplitude = |X[k]| / (N/2) / coherent_gain = |X[k]| * 4 / N
    max_mag * 4.0 / fft_size as f32
}

/// 测量信号的 RMS
fn rms(samples: &[f32]) -> f32 {
    let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

/// 测量真峰值（4x 过采样）
fn true_peak(samples: &[f32]) -> f32 {
    let mut max = 0.0f32;
    for w in samples.windows(2) {
        // 简单线性插值 4x
        for i in 0..4 {
            let t = i as f32 / 4.0;
            let v = w[0] + (w[1] - w[0]) * t;
            if v.abs() > max { max = v.abs(); }
        }
    }
    max
}

/// 生成立体声正弦波 WAV
fn generate_sine_wav(path: &str, freq: f32, amplitude: f32, sample_rate: u32, channels: u16, duration_secs: f64) {
    let _ = std::fs::remove_file(path);
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 24,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let frames = (sample_rate as f64 * duration_secs) as u32;
    let scale = (1 << 23) - 1; // 24-bit max
    for i in 0..frames {
        let t = i as f32 / sample_rate as f32;
        let s = (t * freq * 2.0 * std::f32::consts::PI).sin() * amplitude;
        for _ in 0..channels {
            writer.write_sample((s * scale as f32) as i32).unwrap();
        }
    }
    writer.finalize().unwrap();
}

/// 生成 5.1 声道 WAV（FL FR FC LFE RL RR）
fn generate_51_wav(path: &str, sample_rate: u32, duration_secs: f64) {
    let _ = std::fs::remove_file(path);
    let spec = hound::WavSpec {
        channels: 6,
        sample_rate,
        bits_per_sample: 24,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let frames = (sample_rate as f64 * duration_secs) as u32;
    let scale = (1 << 23) - 1;
    for i in 0..frames {
        let t = i as f32 / sample_rate as f32;
        // FL=0.3, FR=0.3, FC=0.5, LFE=0, RL=0.2, RR=0.2
        let fl = (t * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.3;
        let fr = (t * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.3;
        let fc = (t * 1000.0 * 2.0 * std::f32::consts::PI).sin() * 0.5;
        let lfe = 0.0f32;
        let rl = (t * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.2;
        let rr = (t * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.2;
        for &s in &[fl, fr, fc, lfe, rl, rr] {
            writer.write_sample((s * scale as f32) as i32).unwrap();
        }
    }
    writer.finalize().unwrap();
}

/// 解码文件到内存（立体声）
fn decode(path: &str, sr: u32) -> Vec<f32> {
    decode_to_memory(Path::new(path), sr, 2).unwrap_or_default()
}

/// 提取左声道
fn left_channel(interleaved: &[f32]) -> Vec<f32> {
    interleaved.iter().step_by(2).copied().collect()
}

// ── 测试 ──

/// 1kHz 正弦波解码后频率和幅度应精确
#[test]
fn test_decode_sine_frequency_accuracy() {
    let path = "/tmp/_sig_1k.wav";
    generate_sine_wav(path, 1000.0, 0.5, 44100, 2, 1.0);
    let samples = decode(path, 44100);
    assert!(samples.len() > 44100, "解码样本不足: {}", samples.len());

    let left = left_channel(&samples);
    let amp = measure_amplitude_at(&left, 1000.0, 44100);

    // 幅度应接近 0.5（±20%，考虑 Hann 窗 scalloping loss 和量化误差）
    assert!(
        (amp - 0.5).abs() < 0.1,
        "1kHz 幅度偏差: 期望 0.5, 实测 {amp}"
    );

    // 验证 1kHz 是主频（比其他频率至少高 20dB）
    let amp_500 = measure_amplitude_at(&left, 500.0, 44100);
    let amp_2k = measure_amplitude_at(&left, 2000.0, 44100);
    assert!(
        amp > amp_500 * 10.0,
        "500Hz 分量过大: 1kHz={amp}, 500Hz={amp_500}"
    );
    assert!(
        amp > amp_2k * 10.0,
        "2kHz 分量过大: 1kHz={amp}, 2kHz={amp_2k}"
    );
}

/// 48kHz 文件解码到 44.1kHz 后频率应保持不变
#[test]
fn test_resample_preserves_frequency() {
    let path = "/tmp/_sig_48k.wav";
    generate_sine_wav(path, 1000.0, 0.5, 48000, 2, 1.0);
    let samples = decode(path, 44100); // 重采样到 44100
    assert!(samples.len() > 40000, "重采样后样本不足: {}", samples.len());

    let left = left_channel(&samples);
    let amp_1k = measure_amplitude_at(&left, 1000.0, 44100);
    let amp_5k = measure_amplitude_at(&left, 5000.0, 44100);

    assert!(
        (amp_1k - 0.5).abs() < 0.12,
        "重采样后 1kHz 幅度偏差: 期望 0.5, 实测 {amp_1k}"
    );
    assert!(
        amp_1k > amp_5k * 20.0,
        "重采样引入过多高频噪声: 1kHz={amp_1k}, 5kHz={amp_5k}"
    );
}

/// 5.1 声道 downmix 到立体声：中置应混入，环绕应混入
#[test]
fn test_51_downmix_includes_center() {
    let path = "/tmp/_sig_51.wav";
    generate_51_wav(path, 44100, 1.0);
    let samples = decode(path, 44100);
    assert!(samples.len() > 44100, "5.1 解码样本不足: {}", samples.len());

    let left = left_channel(&samples);

    // 440Hz 来自 FL(0.3) + RL(0.2)*0.707 = 0.3 + 0.141 = 0.441
    let amp_440 = measure_amplitude_at(&left, 440.0, 44100);
    // 1kHz 来自 FC(0.5)*0.707 = 0.354
    let amp_1k = measure_amplitude_at(&left, 1000.0, 44100);

    assert!(
        amp_440 > 0.3,
        "5.1 downmix 后 440Hz 幅度过低（FL+RL 未正确混入）: {amp_440}"
    );
    assert!(
        amp_1k > 0.2,
        "5.1 downmix 后 1kHz 幅度过低（FC 未正确混入）: {amp_1k}"
    );
    // 中置衰减后应约为 0.354（±25%，窗函数损耗）
    assert!(
        (amp_1k - 0.354).abs() < 0.1,
        "FC downmix 幅度偏差: 期望 ~0.354, 实测 {amp_1k}"
    );
}

/// 解码 → PEQ(+6dB@1kHz) → 验证 1kHz 增益约 +6dB
#[test]
fn test_full_chain_peq_gain() {
    let path = "/tmp/_sig_peq.wav";
    generate_sine_wav(path, 1000.0, 0.3, 44100, 2, 1.0);
    let samples = decode(path, 44100);
    let left = left_channel(&samples);

    // 不加 EQ 的基线幅度
    let amp_before = measure_amplitude_at(&left, 1000.0, 44100);

    // 过 PEQ：1kHz +6dB
    let bands = vec![PeqBand { freq: 1000.0, gain_db: 6.0, q: 1.0 }];
    let mut dsp = DspPipeline::new(44100, 2, &bands, false, 1.0, 24);
    let mut buf = samples.clone();
    // 分帧处理（模拟实际 consumer 行为）
    for chunk in buf.chunks_mut(4096) {
        dsp.process(chunk);
    }
    let left_after = left_channel(&buf);
    let amp_after = measure_amplitude_at(&left_after, 1000.0, 44100);

    let gain_db = 20.0 * (amp_after / amp_before.max(1e-10)).log10();
    assert!(
        (gain_db - 6.0).abs() < 0.5,
        "PEQ +6dB@1kHz 实测增益: {gain_db:.1}dB (before={amp_before}, after={amp_after})"
    );
}

/// 解码 → PEQ(-12dB@1kHz) → 验证 1kHz 被衰减
#[test]
fn test_full_chain_peq_cut() {
    let path = "/tmp/_sig_peq_cut.wav";
    generate_sine_wav(path, 1000.0, 0.5, 44100, 2, 1.0);
    let samples = decode(path, 44100);

    let bands = vec![PeqBand { freq: 1000.0, gain_db: -12.0, q: 1.0 }];
    let mut dsp = DspPipeline::new(44100, 2, &bands, false, 1.0, 24);
    let mut buf = samples.clone();
    for chunk in buf.chunks_mut(4096) {
        dsp.process(chunk);
    }

    let left = left_channel(&buf);
    let amp = measure_amplitude_at(&left, 1000.0, 44100);

    // 0.5 * 10^(-12/20) = 0.5 * 0.251 = 0.126
    assert!(
        amp < 0.2,
        "PEQ -12dB 后 1kHz 应大幅衰减: 实测 {amp}"
    );
    assert!(
        amp > 0.05,
        "PEQ -12dB 后 1kHz 不应完全消失: 实测 {amp}"
    );
}

/// 满刻度信号经全管线（31段PEQ + crossfeed + limiter + dither）不削波
#[test]
fn test_full_chain_no_clipping() {
    let path = "/tmp/_sig_clip.wav";
    generate_sine_wav(path, 1000.0, 0.95, 44100, 2, 0.5);
    let samples = decode(path, 44100);

    let bands = audio_core::dsp::default_peq_bands();
    let mut dsp = DspPipeline::new(44100, 2, &bands, true, 1.0, 24);
    let mut buf = samples.clone();
    for chunk in buf.chunks_mut(4096) {
        dsp.process(chunk);
    }

    let tp = true_peak(&buf);
    assert!(
        tp <= 1.0 + 0.001,
        "全管线输出真峰值超限: {tp}"
    );
}

/// WAV 和 FLAC 解码同一信号，结果应高度一致
#[test]
fn test_format_consistency_wav_flac() {
    let fixtures = common::ensure_fixtures();
    let wav = decode(&fixtures.wav, 44100);
    let flac = decode(&fixtures.flac, 44100);

    if flac.is_empty() {
        eprintln!("FLAC 夹具不可用，跳过");
        return;
    }

    let min_len = wav.len().min(flac.len());
    assert!(min_len > 44100, "解码样本不足");

    // 计算归一化互相关（应接近 1.0）
    let w = &wav[..min_len];
    let f = &flac[..min_len];
    let dot: f64 = w.iter().zip(f).map(|(&a, &b)| a as f64 * b as f64).sum();
    let norm_w: f64 = w.iter().map(|&s| s as f64 * s as f64).sum();
    let norm_f: f64 = f.iter().map(|&s| s as f64 * s as f64).sum();
    let correlation = dot / (norm_w * norm_f).sqrt();

    assert!(
        correlation > 0.999,
        "WAV/FLAC 解码不一致: 互相关 = {correlation}"
    );
}

/// seek 后首帧 PTS 应接近目标位置
#[test]
fn test_seek_pts_accuracy() {
    let path = "/tmp/_sig_seek.wav";
    generate_sine_wav(path, 440.0, 0.5, 44100, 2, 3.0);

    let seek_target = 1.5; // 秒
    let (rx, _dec) = Decoder::start(
        Path::new(path), 44100, 2,
        Arc::new(AtomicU64::new(0)),
        Some(seek_target), None,
    ).unwrap();

    let mut first_pts = None;
    let mut total = 0usize;
    while let Ok(f) = rx.recv_timeout(Duration::from_secs(3)) {
        if first_pts.is_none() {
            first_pts = Some(f.pts_secs);
        }
        total += f.samples.len();
        if total > 44100 * 2 { break; } // 收够 1 秒
    }

    let pts = first_pts.expect("应收到至少一帧");
    let delta = (pts - seek_target).abs();
    assert!(
        delta < 0.05,
        "seek PTS 偏差过大: 目标 {seek_target}s, 实际 {pts}s (Δ={delta}s)"
    );
}

/// 单声道文件解码到立体声：左右应相同
#[test]
fn test_mono_to_stereo_duplication() {
    let path = "/tmp/_sig_mono.wav";
    generate_sine_wav(path, 1000.0, 0.5, 44100, 1, 0.5);
    let samples = decode(path, 44100);
    assert!(samples.len() > 1000, "解码样本不足");

    // 检查 L == R
    let mut max_diff = 0.0f32;
    for chunk in samples.chunks(2) {
        if chunk.len() == 2 {
            let diff = (chunk[0] - chunk[1]).abs();
            if diff > max_diff { max_diff = diff; }
        }
    }
    assert!(
        max_diff < 1e-6,
        "单声道→立体声后 L/R 不一致: max_diff={max_diff}"
    );
}

/// 静音文件解码后应全零（或接近零）
#[test]
fn test_silence_decodes_to_near_zero() {
    let path = "/tmp/_sig_silence.wav";
    generate_sine_wav(path, 1000.0, 0.0, 44100, 2, 0.5); // amplitude=0
    let samples = decode(path, 44100);
    assert!(samples.len() > 1000, "解码样本不足");

    let r = rms(&samples);
    assert!(
        r < 0.001,
        "静音文件 RMS 应接近零: {r}"
    );
}

/// 不同频率正弦波的解码幅度一致性（频响平坦度）
#[test]
fn test_decode_flat_frequency_response() {
    let freqs = [100.0f32, 500.0, 1000.0, 5000.0, 10000.0];
    let mut amplitudes = Vec::new();

    for &freq in &freqs {
        let path = format!("/tmp/_sig_flat_{freq}.wav");
        generate_sine_wav(&path, freq, 0.5, 44100, 2, 1.0);
        let samples = decode(&path, 44100);
        let left = left_channel(&samples);
        let amp = measure_amplitude_at(&left, freq, 44100);
        amplitudes.push(amp);
    }

    // 所有频率的幅度应接近 0.5（低频 scalloping 更大，容差放宽）
    for (i, &freq) in freqs.iter().enumerate() {
        assert!(
            (amplitudes[i] - 0.5).abs() < 0.15,
            "频响不平坦: {freq}Hz 幅度 {} (期望 0.5)",
            amplitudes[i]
        );
    }

    // 最大最小差异 < 1.5dB
    let max_amp = amplitudes.iter().cloned().fold(0.0f32, f32::max);
    let min_amp = amplitudes.iter().cloned().fold(f32::MAX, f32::min);
    let ripple_db = 20.0 * (max_amp / min_amp).log10();
    assert!(
        ripple_db < 1.5,
        "频响波纹过大: {ripple_db:.2}dB (max={max_amp}, min={min_amp})"
    );
}
