//! 测量 Decoder 输出的峰值是否全程有数据（而非只在开头）
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

#[test]
fn decode_peak_over_time() {
    let path = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";
    let (rx, dec) = audio_core::decoder::Decoder::start(
        std::path::Path::new(path), 44100, 2,
        Arc::new(AtomicU64::new(0)), None,
    ).unwrap();
    let mut frames_with_data = 0u64;
    let mut total = 0u64;
    let start = std::time::Instant::now();
    while let Ok(frame) = rx.recv() {
        total += 1;
        let pk = frame.samples.iter().map(|&v| v.abs()).fold(0.0f32, f32::max);
        if pk > 1e-3 { frames_with_data += 1; }
        let el = start.elapsed().as_secs_f32();
        if total <= 20 || total % 500 == 0 {
            eprintln!("[PK] frame#{} len={} peak={:.4} t={:.2}s",
                      total, frame.samples.len(), pk, el);
        }
        if start.elapsed() > std::time::Duration::from_secs(4) { break; }
    }
    eprintln!("[PK] 4秒内: 总帧={} 有数据帧={}", total, frames_with_data);
    dec.stop();
}
