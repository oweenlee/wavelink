//! 复现 iOS"次啦次啦"：headless 引擎 48k，播 44.1k 文件，按实时节奏消费
//! 统计 underrun 是否阵发。
//! 用法: cargo run --release --no-default-features --example underrun_repro

#[cfg(target_os = "macos")]
#[allow(clippy::duplicated_attributes)] // 多个 #[link] 的 kind = "framework" 会被 clippy 误报为重复属性
#[link(name = "CoreAudio", kind = "framework")]
#[link(name = "AudioToolbox", kind = "framework")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {}

use audio_core::engine::EngineHandle;
use audio_core::EngineConfig;
use std::time::{Duration, Instant};

fn main() {
    // 生成 30s 44.1k 立体声 wav（模拟用户的 44.1k 文件）
    let path = "/tmp/wavelink_underrun_test.wav";
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44100,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    for i in 0..(44100 * 30) {
        let s = ((i as f32 / 44100.0 * 440.0 * 2.0 * std::f32::consts::PI).sin()
            * 0.3
            * i16::MAX as f32) as i16;
        w.write_sample(s).unwrap();
        w.write_sample(s).unwrap();
    }
    w.finalize().unwrap();

    // 引擎 48k 输出（= iOS 外放链路：44.1k → 48k resample）
    let config = EngineConfig {
        sample_rate: 48000,
        channels: 2,
        buffer_ms: 280,
        ..Default::default()
    };
    let (handle, _rx) = EngineHandle::start_with_config(config);
    handle.play_sync(path.to_string()).expect("play failed");
    eprintln!("playing 44.1k→48k, consuming realtime 1024-frame chunks @48k...");

    let mut buf = vec![0f32; 1024 * 2];
    let mut underruns = 0u64;
    let mut zero_runs: Vec<(f64, usize)> = Vec::new(); // (发生时刻, 连续短读次数)
    let mut current_run = 0usize;
    let mut frames_out = 0u64;
    let start = Instant::now();
    let chunk_dur = Duration::from_secs_f64(1024.0 / 48000.0);
    let mut next = start;
    let mut last_report = start;

    loop {
        let now = Instant::now();
        let t = now.duration_since(start);
        if t > Duration::from_secs(26) {
            break;
        }
        if now < next {
            std::thread::sleep(next - now);
        }
        next += chunk_dur;

        let n = handle.read_samples(&mut buf);
        frames_out += (n / 2) as u64;
        if n < buf.len() {
            underruns += 1;
            current_run += 1;
        } else if current_run > 0 {
            zero_runs.push((t.as_secs_f64(), current_run));
            current_run = 0;
        }
        if last_report.elapsed() > Duration::from_secs(5) {
            println!(
                "t={:5.1}s  underruns={:<4} 输出={:.2}s（应≈{:.1}s）",
                t.as_secs_f64(),
                underruns,
                frames_out as f64 / 48000.0,
                t.as_secs_f64()
            );
            last_report = now;
        }
    }
    if current_run > 0 {
        zero_runs.push((26.0, current_run));
    }

    println!("\n== 结果：underrun 总数 = {underruns}");
    for (t, run) in &zero_runs {
        println!(
            "  t≈{t:.1}s 处连续 {run} 次短读（约 {:.0}ms 缺口）",
            *run as f64 * 21.3
        );
    }
    if underruns == 0 {
        println!("  本地无 underrun —— 引擎链路干净，问题在设备侧环境");
    }
    handle.stop();
}
