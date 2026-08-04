//! 损坏文件和边界文件解码测试
//!
//! 验证 Decoder 对各类损坏输入的处理不会 panic，
//! 能够优雅地返回错误或跳过。

use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Duration;

use audio_core::decoder::Decoder;

/// 解码文件，返回是否产生了任何帧
fn decode_expect_err(path: &str) -> bool {
    let result = Decoder::start(
        std::path::Path::new(path),
        44100, 2,
        Arc::new(AtomicU64::new(0)), None, None,
    );
    match result {
        Ok((rx, _dec)) => {
            let mut had_frames = false;
            while rx.recv_timeout(Duration::from_secs(3)).is_ok() {
                had_frames = true;
            }
            had_frames
        }
        Err(_) => false,
    }
}

#[test]
fn test_zero_byte_file() {
    let path = "/tmp/_corrupted_empty.wav";
    std::fs::write(path, []).ok();
    let had_frames = decode_expect_err(path);
    assert!(!had_frames, "0 字节文件不应产生任何帧");
    let _ = std::fs::remove_file(path);
}

#[test]
fn test_truncated_wav_header() {
    let path = "/tmp/_corrupted_truncated.wav";
    // 仅 20 字节（RIFF 头不完整，缺 fmt 块）
    let data = vec![
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x00, 0x00, 0x00, 0x00, // size
        0x57, 0x41, 0x56, 0x45, // WAVE
        0x66, 0x6D, 0x74, 0x20, // "fmt "
        0x10, 0x00, 0x00, 0x00, // chunk size = 16
    ];
    std::fs::write(path, &data).ok();
    let had_frames = decode_expect_err(path);
    assert!(!had_frames, "截断 WAV 不应产生任何帧");
    let _ = std::fs::remove_file(path);
}

#[test]
fn test_garbage_file() {
    let path = "/tmp/_corrupted_garbage.bin";
    let data: Vec<u8> = (0..512).map(|i| (i * 17 + 43) as u8).collect();
    std::fs::write(path, &data).ok();
    let had_frames = decode_expect_err(path);
    assert!(!had_frames, "垃圾数据不应产生任何帧");
    let _ = std::fs::remove_file(path);
}

#[test]
fn test_wav_with_nan_samples() {
    let path = "/tmp/_corrupted_nan.wav";
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44100,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    {
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        let n = 100 * 2; // 100 个立体声帧
        for _ in 0..n {
            writer.write_sample(f32::NAN).unwrap();
        }
        writer.finalize().unwrap();
    }

    // 解码不应 panic（可能产生 NaN 帧，但 consumer 层会检测）
    let _had_frames = decode_expect_err(path);
    let _ = std::fs::remove_file(path);
}

#[test]
fn test_wav_zero_length_data_chunk() {
    let path = "/tmp/_corrupted_zero_data.wav";
    // 合法 RIFF/WAVE 头，但 data chunk 大小为 0
    let data = vec![
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x24, 0x00, 0x00, 0x00, // file size - 8
        0x57, 0x41, 0x56, 0x45, // WAVE
        0x66, 0x6D, 0x74, 0x20, // "fmt "
        0x10, 0x00, 0x00, 0x00, // chunk size = 16
        0x01, 0x00,             // PCM
        0x02, 0x00,             // channels = 2
        0x44, 0xAC, 0x00, 0x00, // sample rate = 44100
        0x88, 0x58, 0x01, 0x00, // byte rate = 88200
        0x04, 0x00,             // block align = 4
        0x10, 0x00,             // bits per sample = 16
        0x64, 0x61, 0x74, 0x61, // "data"
        0x00, 0x00, 0x00, 0x00, // data size = 0
    ];
    std::fs::write(path, &data).ok();
    let had_frames = decode_expect_err(path);
    assert!(!had_frames, "0 字节 data chunk 不应产生帧");
    let _ = std::fs::remove_file(path);
}
