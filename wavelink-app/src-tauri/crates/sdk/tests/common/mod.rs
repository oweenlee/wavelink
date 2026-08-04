//! 测试夹具：自动生成 WAV，通过 FFmpeg 转码为各格式

#![allow(dead_code)]
//! 供 decoder 和 format_verification 测试使用

use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

static FIXTURES_READY: OnceLock<()> = OnceLock::new();

/// 测试用音频文件路径
pub struct TestAudio {
    pub wav: String,
    pub mp3: String,
    pub flac: String,
    pub ogg: String,
    pub m4a: String,
    pub wav_48k: String,
    pub wavpack: String,
    pub aiff: String,
}

impl TestAudio {
    pub fn all_paths(&self) -> Vec<&str> {
        vec![&self.wav, &self.mp3, &self.flac, &self.ogg, &self.m4a, &self.wav_48k, &self.wavpack, &self.aiff]
    }
}

/// 确保测试夹具就绪（保证只运行一次）
pub fn ensure_fixtures() -> TestAudio {
    FIXTURES_READY.get_or_init(|| {
        generate_wav("/tmp/test_tone.wav", 44100, 2, 2.0);
        generate_wav("/tmp/test_48k.wav", 48000, 2, 2.0);
        try_convert("/tmp/test_tone.wav", "/tmp/test_mp3.mp3");
        try_convert("/tmp/test_tone.wav", "/tmp/test_flac.flac");
        try_convert_ogg("/tmp/test_tone.wav", "/tmp/test_opus.opus");
        try_convert("/tmp/test_tone.wav", "/tmp/test_aac.m4a");
        try_convert("/tmp/test_tone.wav", "/tmp/test_wavpack.wv");
        try_convert("/tmp/test_tone.wav", "/tmp/test_aiff.aiff");
    });

    TestAudio {
        wav: "/tmp/test_tone.wav".into(),
        mp3: "/tmp/test_mp3.mp3".into(),
        flac: "/tmp/test_flac.flac".into(),
        ogg: "/tmp/test_opus.opus".into(),
        m4a: "/tmp/test_aac.m4a".into(),
        wav_48k: "/tmp/test_48k.wav".into(),
        wavpack: "/tmp/test_wavpack.wv".into(),
        aiff: "/tmp/test_aiff.aiff".into(),
    }
}

/// 用 hound 生成标准正弦波 WAV
fn generate_wav(path: &str, sample_rate: u32, channels: u16, duration_secs: f64) {
    if Path::new(path).exists() { return; }
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let total_samples = (sample_rate as f64 * duration_secs) as u32 * channels as u32;
    for i in 0..total_samples {
        let t = i as f64 / sample_rate as f64;
        let sample = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.5;
        writer.write_sample((sample * i16::MAX as f64) as i16).unwrap();
    }
    writer.finalize().ok();
    eprintln!("已生成: {path}");
}

/// 用 ffmpeg 转码（路径不存在时尝试）
fn try_convert(input: &str, output: &str) {
    if Path::new(output).exists() { return; }
    let status = std::process::Command::new("ffmpeg")
        .args(["-y", "-i", input, output])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    match status {
        Ok(s) if s.success() => eprintln!("已转码: {input} -> {output}"),
        _ => eprintln!("ffmpeg 转码失败, 跳过: {output}"),
    }
}

/// OGG 显式指定 Opus 编码（新版 ffmpeg 默认用 FLAC，lofty 无法解析）
fn try_convert_ogg(input: &str, output: &str) {
    if Path::new(output).exists() && std::fs::metadata(output).map(|m| m.len() > 0).unwrap_or(false) { return; }
    let status = std::process::Command::new("ffmpeg")
        .args(["-y", "-i", input, "-c:a", "libopus", output])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    match status {
        Ok(s) if s.success() => eprintln!("已转码: {input} -> {output}"),
        _ => eprintln!("ffmpeg 转码失败, 跳过: {output}"),
    }
}

/// 超时等待从解码 channel 接收帧
pub fn drain_rx(
    rx: &crossbeam_channel::Receiver<audio_core::decoder::DecodedFrame>,
    timeout: Duration,
) -> Vec<audio_core::decoder::DecodedFrame> {
    let mut frames = Vec::new();
    loop {
        match rx.recv_timeout(timeout) {
            Ok(frame) => frames.push(frame),
            Err(crossbeam_channel::RecvTimeoutError::Timeout)
            | Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }
    frames
}
