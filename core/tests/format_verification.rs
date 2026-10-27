//! 格式验证集成测试

mod common;

use audio_core::decoder::Decoder;
use audio_core::{TARGET_CHANNELS, TARGET_SAMPLE_RATE};
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Duration;

fn decode_count(path: &str) -> Result<(u64, usize), String> {
    let (rx, _decoder) = Decoder::start(
        std::path::Path::new(path),
        TARGET_SAMPLE_RATE,
        TARGET_CHANNELS,
        Arc::new(AtomicU64::new(0)),
        None,
        None,
    )
    .map_err(|e| format!("Decoder::start 失败: {e}"))?;
    let mut total = 0u64;
    let mut chunks = 0usize;
    while let Ok(frame) = rx.recv_timeout(Duration::from_secs(5)) {
        total += frame.samples.len() as u64;
        chunks += 1;
    }
    if chunks == 0 {
        return Err("无音频帧".into());
    }
    Ok((total, chunks))
}

#[test]
fn test_wav() {
    let a = common::ensure_fixtures();
    match decode_count(&a.wav) {
        Ok((cnt, chk)) => {
            assert!(chk > 0);
            assert!((150_000..=250_000).contains(&cnt), "WAV samples: {cnt}");
        }
        Err(e) => panic!("WAV decode failed: {e}"),
    }
}

/// 解码样本并返回总样本数。
///
/// 样本由 `common::ensure_fixtures` 经 ffmpeg 转码生成；ffmpeg 不可用时文件不存在，
/// 打印 [SKIP] 并返回 None。
///
/// **不要写成 `if let Ok(..) = decode_count(..)`**：那会让"解码失败"静默变成测试通过，
/// 而解码回归正是这些用例唯一要防的东西。
fn fixture_samples(label: &str, path: &str) -> Option<u64> {
    if !std::path::Path::new(path).exists() {
        eprintln!("[SKIP] {label} 样本未生成（需要 ffmpeg）: {path}");
        return None;
    }
    match decode_count(path) {
        Ok((total, chunks)) => {
            assert!(chunks > 0, "{label} 解码后无音频帧");
            Some(total)
        }
        Err(e) => panic!("{label} 解码失败: {e}"),
    }
}

#[test]
fn test_mp3() {
    let a = common::ensure_fixtures();
    let Some(cnt) = fixture_samples("MP3", &a.mp3) else {
        return;
    };
    assert!(cnt > 10_000, "MP3 samples: {cnt}");
}

#[test]
fn test_flac() {
    let a = common::ensure_fixtures();
    let Some(cnt) = fixture_samples("FLAC", &a.flac) else {
        return;
    };
    assert!(cnt > 10_000, "FLAC samples: {cnt}");
}

#[test]
fn test_ogg() {
    let a = common::ensure_fixtures();
    let Some(cnt) = fixture_samples("OGG/Opus", &a.ogg) else {
        return;
    };
    assert!(cnt > 10_000, "OGG samples: {cnt}");
}

#[test]
fn test_m4a() {
    let a = common::ensure_fixtures();
    let Some(cnt) = fixture_samples("M4A/AAC", &a.m4a) else {
        return;
    };
    assert!(cnt > 10_000, "M4A samples: {cnt}");
}

#[test]
fn test_wav_48k() {
    let a = common::ensure_fixtures();
    let (cnt, _) = decode_count(&a.wav_48k).unwrap();
    // 48kHz 2s stereo → 44.1kHz: 理论 176400 样本。
    // EOF 冲刷重采样器会补零输出最后一个块（1024 帧 = 2048 样本）的 sinc 尾部，
    // 因此输出应 ≥ 理论值且 ≤ 理论值 + 一个块；旧实现会截断曲尾 ~272 样本（176128）。
    assert!(
        (176400..=178448).contains(&cnt),
        "48kHz WAV samples: {cnt} (expected 176400..=178448)"
    );
}

#[test]
fn test_aiff() {
    let a = common::ensure_fixtures();
    let Some(cnt) = fixture_samples("AIFF", &a.aiff) else {
        return;
    };
    assert!(cnt > 10_000, "AIFF samples: {cnt}");
}
