//! Seek 样本精度验证
//!
//! 播放器正确性硬指标：seek 到时间 T 后，首个解码样本应落在样本下标
//! S = T × sample_rate 处（Accurate seek），而非偏移若干毫秒。
//!
//! 方法：生成单调斜坡 WAV（样本值唯一对应其下标），seek 到多个位置，
//! 读取首个解码样本，断言其值与期望下标的斜坡值吻合（容差约 ±几个样本，
//! 受 16-bit 量化限制；足以捕获 ms 级的 seek 错误）。

use std::sync::Arc;
use std::time::Duration;

use audio_core::decoder::Decoder;

const SR: usize = 44100;
const N: usize = SR; // 1 秒

/// 生成单调斜坡 WAV：frame i 的值 = (i/N)*1.8 - 0.9（从 -0.9 线性升到 +0.9）。
/// 值单调 → 每个值唯一对应一个样本下标，可由值反推 seek 落点。
fn write_ramp_wav(path: &str) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: SR as u32,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    for i in 0..N {
        let v = ((i as f32 / N as f32) * 1.8 - 0.9) * 32767.0;
        let s = v.clamp(-32768.0, 32767.0) as i16;
        w.write_sample(s).unwrap(); // L
        w.write_sample(s).unwrap(); // R
    }
    w.finalize().unwrap();
}

/// 斜坡在样本下标 idx 处的期望值（解码回 f32 后）
fn ramp_value(idx: usize) -> f32 {
    (idx as f32 / N as f32) * 1.8 - 0.9
}

/// seek 到 seek_secs，返回首个解码帧的首个左声道样本
fn first_sample_after_seek(path: &str, seek_secs: f64) -> f32 {
    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) = Decoder::start(
        std::path::Path::new(path),
        SR as u32,
        2,
        pos,
        Some(seek_secs),
        None,
    )
    .expect("Decoder::start(seek) 失败");

    let frame = rx
        .recv_timeout(Duration::from_secs(5))
        .expect("seek 后应解出首帧");
    assert!(!frame.samples.is_empty(), "seek 后首帧不应为空");
    frame.samples[0] // 首个左声道样本
}

#[test]
fn seek_is_sample_accurate() {
    let dir = std::env::temp_dir();
    let path = format!("{}/wavelink_seek_ramp.wav", dir.display());
    write_ramp_wav(&path);

    // 斜坡斜率：每样本 1.8/44100 ≈ 4.08e-5；16-bit 量化误差 ≈ 2.7e-5。
    // 容差 2e-4 ≈ ±5 样本（~0.11ms）——足以捕获 ms 级 seek 错误，量化噪声内不误报。
    const TOL: f32 = 2e-4;

    for seek_secs in [0.10_f64, 0.25, 0.50, 0.75, 0.90] {
        let expected_idx = (seek_secs * SR as f64).round() as usize;
        let expected = ramp_value(expected_idx);
        let actual = first_sample_after_seek(&path, seek_secs);
        let err = (actual - expected).abs();
        assert!(
            err < TOL,
            "seek 到 {seek_secs}s（下标 {expected_idx}）：首样本 {actual}，期望 ≈ {expected}，误差 {err} 超容差 {TOL}（seek 偏移过大）"
        );
    }

    let _ = std::fs::remove_file(&path);
}

/// seek 到 0 应从头开始（首样本 ≈ 斜坡起点 -0.9）
#[test]
fn seek_to_zero_starts_at_beginning() {
    let dir = std::env::temp_dir();
    let path = format!("{}/wavelink_seek_zero.wav", dir.display());
    write_ramp_wav(&path);

    let actual = first_sample_after_seek(&path, 0.0);
    assert!(
        (actual - ramp_value(0)).abs() < 2e-4,
        "seek 到 0 应从斜坡起点开始：首样本 {actual}，期望 ≈ {}",
        ramp_value(0)
    );

    let _ = std::fs::remove_file(&path);
}
