//! 临时：对真实音频输出 BPM / Key / Energy，用于与 librosa 对照
use std::env;
use std::time::Instant;

fn main() {
    for path in env::args().skip(1) {
        let t = Instant::now();
        match audio_core::analysis::analyze_file(std::path::Path::new(&path)) {
            Ok(r) => println!(
                "{}\tbpm={:?}\tkey={:?}\tenergy={:.3}\t{:.1}s",
                std::path::Path::new(&path)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy(),
                r.bpm,
                r.key,
                r.energy.unwrap_or(0.0),
                t.elapsed().as_secs_f32()
            ),
            Err(e) => println!("{}\tERROR {e}", path),
        }
    }
}
