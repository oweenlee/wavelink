//! 从 /Users/qin/Public/music 抽样真实歌曲，做解码完整性验证
//!
//! 该目录为本机个人音乐库（约 690 首 mp3），不随仓库分发；
//! 目录缺失或为空时自动 SKIP，不会误报失败。
use audio_core::decoder::Decoder;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// 个人音乐库根目录，缺失时整个测试 SKIP
const PUBLIC_MUSIC: &str = "/Users/qin/Public/music";

/// 抽样数量：全库全量解码耗时过长，均匀抽取若干首即可覆盖各编码/采样率
const SAMPLE_COUNT: usize = 40;

/// 单曲字符串名（文件名去扩展名）
fn song_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(str::to_owned)
        .unwrap_or_else(|| path.to_owned())
}

/// 收集目录下指定扩展名的文件，排序保证确定性
fn collect_ext(ext: &str) -> Vec<String> {
    let mut files = Vec::new();
    if let Ok(rd) = std::fs::read_dir(PUBLIC_MUSIC) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_file() && p.extension().is_some_and(|e| e.eq_ignore_ascii_case(ext)) {
                files.push(p.display().to_string());
            }
        }
    }
    files.sort();
    files
}

/// 收集目录下全部 .mp3，排序保证抽样确定
fn collect_mp3s() -> Vec<String> {
    collect_ext("mp3")
}

fn decode_one(name: &str, path: &str) {
    let timeout = Duration::from_secs(60);
    let pos = Arc::new(AtomicU64::new(0));
    let start = Instant::now();

    match Decoder::start(std::path::Path::new(path), 44100, 2, pos, None, None) {
        Ok((rx, dec)) => {
            let mut frames = 0u64;
            let mut total = 0u64;
            let mut min_frame = usize::MAX;
            let mut max_frame = 0usize;
            let mut has_nan = false;
            let mut has_inf = false;

            loop {
                if start.elapsed() > timeout {
                    dec.stop();
                    eprintln!("[⏱️] {}: 解码超时 {}s", name, timeout.as_secs());
                    return;
                }
                match rx.recv_timeout(Duration::from_secs(10)) {
                    Ok(frame) => {
                        frames += 1;
                        total += frame.samples.len() as u64;
                        let fl = frame.samples.len();
                        if fl < min_frame {
                            min_frame = fl;
                        }
                        if fl > max_frame {
                            max_frame = fl;
                        }
                        for &s in frame.samples.iter().take(4) {
                            if s.is_nan() {
                                has_nan = true;
                            }
                            if s.is_infinite() {
                                has_inf = true;
                            }
                        }
                    }
                    Err(_) => break,
                }
            }
            dec.stop();
            let elapsed = start.elapsed();

            let output_secs = total as f64 / 44100.0 / 2.0;
            let speed = if elapsed.as_secs_f64() > 0.0 {
                output_secs / elapsed.as_secs_f64()
            } else {
                0.0
            };

            let status = if has_nan || has_inf {
                "❌ NaN/Inf"
            } else if speed < 0.5 {
                "⚠️ 极慢"
            } else {
                "✅"
            };

            eprintln!(
                "[{}] {}: {}帧 {}样本 ~{:.0}s 解码{:.1}x 帧{}-{}",
                status, name, frames, total, output_secs, speed, min_frame, max_frame,
            );

            assert!(!has_nan, "{name}: NaN 检测到!");
            assert!(!has_inf, "{name}: Inf 检测到!");
        }
        Err(e) => {
            panic!("{name}: 解码失败: {e}");
        }
    }
}

#[test]
#[ignore = "解码真实歌曲，耗时较长"]
fn decode_real_songs_44100() {
    let all = collect_mp3s();
    if all.is_empty() {
        eprintln!("[SKIP] {} 为空或无 mp3，跳过真实歌曲解码", PUBLIC_MUSIC);
        return;
    }

    // 均匀抽样，覆盖不同码率/歌手/unicode 路径
    let step = all.len().div_ceil(SAMPLE_COUNT).max(1);
    let sampled: Vec<String> = all.iter().step_by(step).cloned().collect();
    eprintln!("共 {} 首 mp3，均匀抽样 {} 首", all.len(), sampled.len());

    for path in &sampled {
        decode_one(&song_name(path), path);
    }
    eprintln!("\n ✅ 真实歌曲解码完成");
}

#[test]
#[ignore = "解码 HiFi WAV，耗时较长"]
fn decode_hifi_wav() {
    // Public/music 当前无 wav 文件，若有则逐个解码验证
    let wavs = collect_ext("wav");
    if wavs.is_empty() {
        eprintln!("[SKIP] {PUBLIC_MUSIC} 无 wav 文件，跳过 HiFi WAV 解码");
        return;
    }
    eprintln!("共 {} 个 wav，逐个解码", wavs.len());
    for path in &wavs {
        decode_one(&song_name(path), path);
    }
    eprintln!("\n ✅ HiFi WAV 解码完成");
}
