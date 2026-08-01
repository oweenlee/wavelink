//! 快速诊断：384kHz WAV 解码速度（只解前 10 秒实际音频数据）
//! 这个文件 ~553MB，全解太慢，所以先探测时长再取前 10s 数据量

use audio_core::decoder::Decoder;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[test]
#[ignore = "解码 384kHz WAV，耗时较长"]
fn diagnose_384k() {
    let path = std::path::Path::new("/Users/qin/Desktop/wavelink/test-media/hifi_ode_to_joy.wav");
    if !path.exists() {
        eprintln!("文件不存在");
        return;
    }

    // 先看文件大小
    let meta = std::fs::metadata(path).unwrap();
    let file_size = meta.len();
    eprintln!("文件大小: {} MB", file_size / 1024 / 1024);

    // 测 3 种目标率的速度（限时 30 秒，看能解多少）
    for &target_rate in &[44100u32, 48000, 96000] {
        let pos = Arc::new(AtomicU64::new(0));
        let start = Instant::now();
        let timeout = Duration::from_secs(30);

        let (rx, dec) = Decoder::start(path, target_rate, 2, pos, None, None).unwrap();

        let mut samples = 0u64;
        let mut frames = 0u64;
        let mut first_frame_time = None;

        loop {
            if start.elapsed() > timeout {
                dec.stop();
                break;
            }
            match rx.recv_timeout(Duration::from_millis(500)) {
                Ok(frame) => {
                    if first_frame_time.is_none() {
                        first_frame_time = Some(start.elapsed());
                    }
                    samples += frame.samples.len() as u64;
                    frames += 1;
                }
                Err(_) => break,
            }
        }
        dec.stop();
        let elapsed = start.elapsed();

        let output_secs = samples as f64 / target_rate as f64 / 2.0;
        let speed = if elapsed.as_secs_f64() > 0.0 {
            output_secs / elapsed.as_secs_f64()
        } else {
            0.0
        };
        let first_frame_us = first_frame_time
            .map(|t| t.as_secs_f64() * 1_000_000.0)
            .unwrap_or(0.0);

        eprintln!("---");
        eprintln!("384kHz → {}Hz:", target_rate);
        eprintln!("  解码耗时: {:.2}s", elapsed.as_secs_f64());
        eprintln!("  输出时长: {:.1}s (目标输出率)", output_secs);
        eprintln!("  帧数: {}, 总样本: {}", frames, samples);
        eprintln!("  首帧延迟: {:.0}µs", first_frame_us);
        eprintln!("  帧平均: {:.1} 样本/帧", if frames > 0 { samples as f64 / frames as f64 } else { 0.0 });
        eprintln!("  解码速度: {:.1}x", speed);

        if speed < 0.5 {
            eprintln!("  ❌ 严重不足: 解 1 秒需要 {:.1}s，必定 underrun",
                1.0 / speed);
        } else if speed < 2.0 {
            eprintln!("  ⚠️ 不足: 解 1 秒需要 {:.1}s，可能 underrun",
                1.0 / speed);
        } else if speed < 5.0 {
            eprintln!("  ⚡ 临界: {:.1}x", speed);
        } else {
            eprintln!("  ✅ 充足");
        }
    }
}
