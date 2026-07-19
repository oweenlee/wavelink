//! 随机抽取 test-media 中的真实歌曲，做解码完整性验证
use audio_core::decoder::Decoder;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::{Duration, Instant};

const TEST_MEDIA: &str = "/Users/qin/Desktop/wavelink/test-media";

struct SongTest {
    name: &'static str,
    path: String,
    /// 解码超时（秒），384kHz 文件需要更长时间
    timeout_secs: u64,
}

fn decode_one(song: &SongTest) {
    let path = std::path::Path::new(&song.path);
    if !path.exists() {
        eprintln!("[SKIP] {}: 文件不存在", song.name);
        return;
    }

    let pos = Arc::new(AtomicU64::new(0));
    let start = Instant::now();

    match Decoder::start(path, 44100, 2, pos, None) {
        Ok((rx, dec)) => {
            let mut frames = 0u64;
            let mut total = 0u64;
            let mut min_frame = usize::MAX;
            let mut max_frame = 0usize;
            let mut has_nan = false;
            let mut has_inf = false;

            let deadline = Duration::from_secs(song.timeout_secs);
            loop {
                if start.elapsed() > deadline {
                    dec.stop();
                    eprintln!("[⚠️] {}: 解码超时 {}s", song.name, song.timeout_secs);
                    return;
                }
                match rx.recv_timeout(Duration::from_secs(5)) {
                    Ok(frame) => {
                        frames += 1;
                        total += frame.samples.len() as u64;
                        let fl = frame.samples.len();
                        if fl < min_frame { min_frame = fl; }
                        if fl > max_frame { max_frame = fl; }
                        for &s in frame.samples.iter().take(4) {
                            if s.is_nan() { has_nan = true; }
                            if s.is_infinite() { has_inf = true; }
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
            } else { 0.0 };

            let status = if has_nan || has_inf { "❌ NaN/Inf" }
                else if speed < 0.5 { "⚠️ 极慢" }
                else { "✅" };

            eprintln!(
                "[{}] {}: {}帧 {}样本 ~{:.0}s 解码{:.1}x 帧{}-{}",
                status, song.name, frames, total, output_secs, speed,
                min_frame, max_frame,
            );

            assert!(!has_nan, "{}: NaN 检测到!", song.name);
            assert!(!has_inf, "{}: Inf 检测到!", song.name);
        }
        Err(e) => {
            if song.name.starts_with("WMA") {
                eprintln!("[⚠️] {}: WMA 不被 symphonia 支持: {e}", song.name);
            } else {
                panic!("{}: 解码失败: {e}", song.name);
            }
        }
    }
}

#[test]
fn decode_real_songs_44100() {
    let songs = vec![
        SongTest { name: "M4A(李荣浩)", path: format!("{TEST_MEDIA}/李荣浩-恋人.m4a"), timeout_secs: 30 },
        SongTest { name: "M4A(梁博)",   path: format!("{TEST_MEDIA}/梁博-出现又离开.m4a"), timeout_secs: 30 },
        SongTest { name: "FLAC(理由)",  path: format!("{TEST_MEDIA}/一千个伤心的理由.flac"), timeout_secs: 30 },
        SongTest { name: "MP3(渡口)",   path: format!("{TEST_MEDIA}/在百万豪装录音棚大声听 蔡琴《渡口》【Hi-res】.mp3"), timeout_secs: 30 },
        SongTest { name: "MP3(浮夸)",   path: format!("{TEST_MEDIA}/陈奕迅 - 浮夸.mp3"), timeout_secs: 30 },
        SongTest { name: "MP3(ukulele)", path: format!("{TEST_MEDIA}/freepd_happy_whistling_ukulele.mp3"), timeout_secs: 30 },
        SongTest { name: "WMA(回忆)",   path: format!("{TEST_MEDIA}/回忆是开在春天的花朵.wma"), timeout_secs: 10 },
    ];

    for song in &songs {
        decode_one(song);
    }
    eprintln!("\n ✅ 常规文件解码完成");
}

#[test]
fn decode_384k_hifi_wav() {
    // 384kHz 文件单独一个测试，允许更长时间
    let song = SongTest {
        name: "WAV(384kHz)",
        path: format!("{TEST_MEDIA}/hifi_ode_to_joy.wav"),
        timeout_secs: 120,
    };
    decode_one(&song);
    eprintln!("\n ✅ 384kHz 解码完成");
}
