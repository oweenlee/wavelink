//! 专门测试之前超时的两个文件
use audio_core::decoder::Decoder;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[test]
#[ignore = "解码完整歌曲，耗时较长，手动运行: cargo test --test check_two_files -- --ignored"]
fn check_timed_out_files() {
    let files = [
        ("李荣浩-恋人.m4a", "/Users/qin/Desktop/wavelink/test-media/李荣浩-恋人.m4a"),
        ("渡口.mp3", "/Users/qin/Desktop/wavelink/test-media/在百万豪装录音棚大声听 蔡琴《渡口》【Hi-res】.mp3"),
    ];

    for (name, path) in &files {
        let p = std::path::Path::new(path);
        if !p.exists() {
            eprintln!("[SKIP] {}: 不存在", name);
            continue;
        }

        let pos = Arc::new(AtomicU64::new(0));
        let start = Instant::now();

        match Decoder::start(p, 44100, 2, pos, None, None) {
            Ok((rx, dec)) => {
                let mut first_frame = None;
                let mut total = 0u64;

                while let Ok(frame) = rx.recv_timeout(Duration::from_secs(10)) {
                    if first_frame.is_none() {
                        first_frame = Some(start.elapsed());
                    }
                    total += frame.samples.len() as u64;
                }
                dec.stop();
                let elapsed = start.elapsed();
                let output_secs = total as f64 / 44100.0 / 2.0;
                let speed = output_secs / elapsed.as_secs_f64();

                eprintln!(
                    "[{}] 首帧 {:?}, 样本 {}, 输出 {:.0}s, 耗时 {:.2}s, 速度 {:.1}x",
                    name, first_frame, total, output_secs, elapsed.as_secs_f64(), speed
                );
            }
            Err(e) => {
                eprintln!("[{}] 解码失败: {}", name, e);
            }
        }
    }
}
