/// 分析真实文件验证 CLI：
///   analysis_cli <file> [max_secs] [--dump-chroma]
/// max_secs 缺省为 None（全曲）；--dump-chroma 额外输出 12 维音级向量
/// （用于与 essentia/librosa 的模板匹配权重离线实验）。
use std::env;
use std::path::Path;
use std::time::Instant;

fn main() {
    let mut args = env::args().skip(1);
    let path = match args.next() {
        Some(p) => p,
        None => {
            eprintln!("用法: analysis_cli <file> [max_secs] [--dump-chroma]");
            return;
        }
    };
    let mut max_secs: Option<f64> = None;
    let mut dump_chroma = false;
    for a in args {
        if a == "--dump-chroma" {
            dump_chroma = true;
        } else if let Ok(v) = a.parse() {
            max_secs = Some(v);
        }
    }

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
        Ok(r) => {
            println!(
                "{}\tmax_secs={:?}\tbpm={:?}\tkey={:?}\tenergy={:.3}\tbpm_conf={:?}\tkey_conf={:?}\t{:.2}s",
                Path::new(&path)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy(),
                max_secs,
                r.bpm,
                r.key,
                r.energy.unwrap_or(0.0),
                r.bpm_confidence,
                r.key_confidence,
                t.elapsed().as_secs_f32()
            );
            if dump_chroma {
                // 与 key 检测同管线：解码 + HPCP，输出 12 维向量
                let samples = audio_core::decoder::decode_to_memory_prefix(
                    Path::new(&path),
                    audio_core::TARGET_SAMPLE_RATE,
                    audio_core::TARGET_CHANNELS,
                    max_secs,
                );
                if let Ok(s) = samples {
                    let mono = audio_core::analysis::mix_to_mono(&s, audio_core::TARGET_CHANNELS);
                    if let Some(c) = audio_core::analysis::key::debug_chromagram(
                        &mono,
                        audio_core::TARGET_SAMPLE_RATE,
                    ) {
                        println!(
                            "CHROMA\t{}\t{}",
                            Path::new(&path)
                                .file_name()
                                .unwrap_or_default()
                                .to_string_lossy(),
                            c.iter()
                                .map(|v| format!("{v:.4}"))
                                .collect::<Vec<_>>()
                                .join(" ")
                        );
                    }
                }
            }
        }
        Err(e) => println!("{}\tERROR {e}", path),
    }
}
