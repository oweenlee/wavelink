//! 真实文件分析验证 CLI：
//!   analysis_cli <file> [max_secs]
//! max_secs 缺省为 None（全曲）；传入则只解码前 N 秒（模拟 analyze_file 截断）。
use std::env;
use std::path::Path;
use std::time::Instant;

fn main() {
    let mut args = env::args().skip(1);
    let path = match args.next() {
        Some(p) => p,
        None => {
            eprintln!("用法: analysis_cli <file> [max_secs]");
            return;
        }
    };
    let max_secs: Option<f64> = args.next().and_then(|s| s.parse().ok());

    let t = Instant::now();
    let result = match max_secs {
        None => audio_core::analysis::analyze_file(Path::new(&path)),
        Some(secs) => audio_core::decoder::decode_to_memory_prefix(
            Path::new(&path),
            audio_core::TARGET_SAMPLE_RATE,
            audio_core::TARGET_CHANNELS,
            Some(secs),
        )
        .map(|s| {
            audio_core::analysis::analyze_from_samples(
                &s,
                audio_core::TARGET_SAMPLE_RATE,
                audio_core::TARGET_CHANNELS,
            )
        })
        .map_err(|e| e.to_string()),
    };

    match result {
        Ok(r) => println!(
            "{}\tmax_secs={:?}\tbpm={:?}\tkey={:?}\tenergy={:.3}\t{:.2}s",
            Path::new(&path).file_name().unwrap_or_default().to_string_lossy(),
            max_secs,
            r.bpm,
            r.key,
            r.energy.unwrap_or(0.0),
            t.elapsed().as_secs_f32()
        ),
        Err(e) => println!("{}\tERROR {e}", path),
    }
}
