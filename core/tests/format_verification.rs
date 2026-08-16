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

#[test]
fn test_mp3() {
    let a = common::ensure_fixtures();
    if let Ok((cnt, _)) = decode_count(&a.mp3) {
        assert!(cnt > 10_000, "MP3 samples: {cnt}");
    }
}

#[test]
fn test_flac() {
    let a = common::ensure_fixtures();
    if let Ok((cnt, _)) = decode_count(&a.flac) {
        assert!(cnt > 10_000, "FLAC samples: {cnt}");
    }
}

#[test]
fn test_ogg() {
    let a = common::ensure_fixtures();
    if let Ok((cnt, _)) = decode_count(&a.ogg) {
        assert!(cnt > 10_000, "OGG samples: {cnt}");
    }
}

#[test]
fn test_m4a() {
    let a = common::ensure_fixtures();
    if let Ok((cnt, _)) = decode_count(&a.m4a) {
        assert!(cnt > 10_000, "M4A samples: {cnt}");
    }
}

#[test]
fn test_wav_48k() {
    let a = common::ensure_fixtures();
    let (cnt, _) = decode_count(&a.wav_48k).unwrap();
    // 48kHz 2s stereo → 44.1kHz: 理论 176400 样本, 重采样器内部延时损失 ~272
    assert!(
        (176000..=176500).contains(&cnt),
        "48kHz WAV samples: {cnt} (expected ~176400)"
    );
}

#[test]
fn test_aiff() {
    let a = common::ensure_fixtures();
    if let Ok((cnt, _)) = decode_count(&a.aiff) {
        assert!(cnt > 10_000, "AIFF samples: {cnt}");
    }
}
