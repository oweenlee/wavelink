//! DoP 直出端到端集成测试
//!
//! 合成一个已知内容的 DSF 文件，走完整 `Decoder::start_dop` 管线，
//! 验证输出的 DoP 帧标记交替、DSD 比特位置、声道交错逐比特正确。

use std::io::Write;
use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Duration;

use audio_core::decoder::{probe_dsd_info, Decoder};

/// 合成最小合法 DSF 文件（每声道填固定字节模式）
fn make_dsf(path: &Path, ch0_byte: u8, ch1_byte: u8, bytes_per_ch: usize) {
    let sample_count = (bytes_per_ch * 8) as u64; // DSD 样本数/声道
    let data_len = bytes_per_ch * 2;
    let total_size = 28u64 + 52 + 12 + data_len as u64;

    let mut f = std::fs::File::create(path).unwrap();

    // DSD chunk
    f.write_all(b"DSD ").unwrap();
    f.write_all(&28u64.to_le_bytes()).unwrap();
    f.write_all(&total_size.to_le_bytes()).unwrap();
    f.write_all(&0u64.to_le_bytes()).unwrap(); // 无元数据

    // fmt chunk
    f.write_all(b"fmt ").unwrap();
    f.write_all(&52u64.to_le_bytes()).unwrap();
    f.write_all(&1u32.to_le_bytes()).unwrap(); // format version
    f.write_all(&0u32.to_le_bytes()).unwrap(); // format id (DSD raw)
    f.write_all(&2u32.to_le_bytes()).unwrap(); // channel type (stereo)
    f.write_all(&2u32.to_le_bytes()).unwrap(); // channel num
    f.write_all(&2_822_400u32.to_le_bytes()).unwrap(); // DSD64
    f.write_all(&1u32.to_le_bytes()).unwrap(); // bits per sample
    f.write_all(&sample_count.to_le_bytes()).unwrap();
    f.write_all(&4096u32.to_le_bytes()).unwrap(); // block size per channel
    f.write_all(&0u32.to_le_bytes()).unwrap(); // reserved

    // data chunk：按块交错（ch0 块 4096, ch1 块 4096, ...）
    f.write_all(b"data").unwrap();
    f.write_all(&(12 + data_len as u64).to_le_bytes()).unwrap();
    let mut ch0_left = bytes_per_ch;
    let mut ch1_left = bytes_per_ch;
    while ch0_left > 0 || ch1_left > 0 {
        let n0 = ch0_left.min(4096);
        if n0 > 0 {
            f.write_all(&vec![ch0_byte; n0]).unwrap();
            ch0_left -= n0;
        }
        let n1 = ch1_left.min(4096);
        if n1 > 0 {
            f.write_all(&vec![ch1_byte; n1]).unwrap();
            ch1_left -= n1;
        }
    }
    f.flush().unwrap();
}

/// 后端 I24 还原公式（与 output_wasapi.rs 一致）
fn decode_i24(s: f32) -> i32 {
    (s * 8_388_608.0).round().clamp(-8_388_608.0, 8_388_607.0) as i32
}

fn dsf_path(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("wavelink_dop_test_{name}.dsf"))
}

#[test]
fn probe_dsd_info_reads_header() {
    let path = dsf_path("probe");
    make_dsf(&path, 0x69, 0x96, 8192);
    let (rate, ch) = probe_dsd_info(&path).expect("应识别 DSF");
    assert_eq!(rate, 2_822_400, "DSD64");
    assert_eq!(ch, 2);
    std::fs::remove_file(&path).ok();
}

#[test]
fn start_dop_produces_valid_dop_stream() {
    let path = dsf_path("stream");
    make_dsf(&path, 0x69, 0x96, 8192);

    let pos = Arc::new(AtomicU64::new(0));
    let (rx, _dec) = Decoder::start_dop(&path, false, 2, pos, None, None)
        .expect("start_dop 应成功");

    let mut all: Vec<f32> = Vec::new();
    let mut frame_rate = 0u32;
    let mut frame_ch = 0u32;
    while let Ok(frame) = rx.recv_timeout(Duration::from_secs(5)) {
        frame_rate = frame.sample_rate;
        frame_ch = frame.channels;
        all.extend_from_slice(&frame.samples);
    }

    assert_eq!(frame_rate, 176_400, "DSD64 的 DoP 速率应为 176.4kHz");
    assert_eq!(frame_ch, 2);
    // 8192 DSD 字节/声道 → 4096 DoP 帧/声道 × 2 声道
    assert_eq!(all.len(), 4096 * 2, "应输出全部 DoP 帧");

    // 逐帧验证：标记交替 + DSD 数据 + 声道交错
    let word_ch0 = 0x05_6969i32; // 标记 A + 0x69,0x69
    let word_ch1 = 0x05_9696i32;
    for frame_idx in 0..4096 {
        let marker: u32 = if frame_idx % 2 == 0 { 0x05 } else { 0xFA };
        let expect_l = se24((marker << 16) | 0x6969);
        let expect_r = se24((marker << 16) | 0x9696);
        let l = decode_i24(all[frame_idx * 2]);
        let r = decode_i24(all[frame_idx * 2 + 1]);
        assert_eq!(l, expect_l, "帧 {frame_idx} 左声道 DoP 字错误");
        assert_eq!(r, expect_r, "帧 {frame_idx} 右声道 DoP 字错误");
        if frame_idx == 0 {
            assert_eq!(l, word_ch0);
            assert_eq!(r, word_ch1);
        }
    }

    std::fs::remove_file(&path).ok();
}

#[test]
fn start_dop_seek_skips_bytes() {
    let path = dsf_path("seek");
    make_dsf(&path, 0x69, 0x96, 8192);

    // seek 到 1024 帧处（= 2048 DSD 字节/声道 = 1024/176400 秒）
    let seek_secs = 1024.0 / 176_400.0;
    let pos = Arc::new(AtomicU64::new(0));
    let (rx, _dec) = Decoder::start_dop(&path, false, 2, pos, Some(seek_secs), None)
        .expect("start_dop seek 应成功");

    let mut count = 0usize;
    while let Ok(frame) = rx.recv_timeout(Duration::from_secs(5)) {
        count += frame.samples.len();
    }
    // 4096 总帧 - ~1024 跳过 ≈ 3072 帧（±1 帧取整误差）× 2 声道
    let frames = count / 2;
    assert!(
        (3000..=3072).contains(&frames),
        "seek 后帧数应约 3072，实际 {frames}"
    );

    std::fs::remove_file(&path).ok();
}

#[test]
fn start_dop_left_justify_mode() {
    let path = dsf_path("leftjust");
    make_dsf(&path, 0x69, 0x96, 4096);

    let pos = Arc::new(AtomicU64::new(0));
    let (rx, _dec) = Decoder::start_dop(&path, true, 2, pos, None, None)
        .expect("start_dop(left_justify) 应成功");

    let mut all: Vec<f32> = Vec::new();
    while let Ok(frame) = rx.recv_timeout(Duration::from_secs(5)) {
        all.extend_from_slice(&frame.samples);
    }
    assert!(!all.is_empty());

    // 左对齐：还原 i32 后高 24 位应为 DoP 字
    let decode_i32 = |s: f32| (s * 2_147_483_648.0).round().clamp(-2_147_483_648.0, 2_147_483_647.0) as i32;
    let first = decode_i32(all[0]);
    let word = se24(0x056969);
    assert_eq!(first, word << 8, "左对齐首样本应为 DoP 字 << 8");

    std::fs::remove_file(&path).ok();
}

/// 24-bit 符号扩展
fn se24(raw: u32) -> i32 {
    if raw & 0x0080_0000 != 0 {
        (raw | 0xFF00_0000) as i32
    } else {
        raw as i32
    }
}
