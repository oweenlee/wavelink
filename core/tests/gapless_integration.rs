//! 无缝播放（gapless）样本级验证
//!
//! HiFi 播放器的硬承诺：曲目切换处样本级连续——无插入静音（gap）、
//! 无样本重复（overlap）、无样本丢失（loss）。现有 engine 测试只验证了
//! "切歌事件触发"，本测试在 consumer 层用真实解码器捕获输出样本，
//! 对衔接处做逐样本断言。
//!
//! 方法：两首恒定电平 WAV（track1=+0.25, track2=-0.25）经 on_end_of_track
//! 链接。若无缝，输出应为 N1 个 +0.25 帧紧接 N2 个 -0.25 帧，总数精确、
//! 衔接处直接跳变、全程无零样本。任何 gap/overlap/loss 都会破坏这些断言。

use std::sync::atomic::{AtomicBool, AtomicU32};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crossbeam_channel::bounded;
use parking_lot::Mutex;

use audio_core::consumer::{run_consumer_loop, ConsumerCallbacks, ConsumerConfig, ConsumerControl};
use audio_core::decoder::Decoder;

/// 生成恒定电平的 16-bit 立体声 WAV，精确 frame_count 帧（44100Hz）
fn write_constant_wav(path: &str, value: f32, frame_count: usize) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44100,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    let v = (value * 32767.0) as i16;
    for _ in 0..frame_count {
        w.write_sample(v).unwrap(); // L
        w.write_sample(v).unwrap(); // R
    }
    w.finalize().unwrap();
}

/// 用真实解码器链接两首曲目，捕获 consumer 输出的全部样本
fn capture_chained_output(track1: &str, track2: &str) -> Vec<f32> {
    let pos1 = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let pos2 = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx1, _dec1) = Decoder::start(std::path::Path::new(track1), 44100, 2, pos1, None, None)
        .expect("decoder1 启动失败");
    let (rx2, _dec2) = Decoder::start(std::path::Path::new(track2), 44100, 2, pos2, None, None)
        .expect("decoder2 启动失败");

    // 预加载的第二首 rx（模拟 engine 的 preload_next），on_end_of_track 取一次
    let next_rx = Arc::new(Mutex::new(Some(rx2)));
    let nr = next_rx.clone();

    let captured = Arc::new(Mutex::new(Vec::new()));
    let cap = captured.clone();

    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0, // 真·无间隙：衔接处不做任何淡入
        recv_timeout_ms: 500,
        passthrough: false,
    };

    let handle = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| {
                cap.lock().extend_from_slice(buf);
                buf.len()
            },
            process_dsp: &|_| {}, // 不过 DSP，样本原样通过
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| nr.lock().take(),
        };
        let ctrl = ConsumerControl {
            stop: s,
            ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx1, &config, &cb, &ctrl);
        // 保持解码器存活至循环结束
        drop(_dec1);
        drop(_dec2);
    });

    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("consumer 应就绪");
    handle.join().expect("consumer 线程不应 panic");

    let out = captured.lock().clone();
    out
}

/// 核心：两首恒定电平曲目衔接处样本级无缝
#[test]
fn gapless_junction_is_sample_accurate() {
    let dir = std::env::temp_dir();
    let t1 = format!("{}/wavelink_gapless_t1.wav", dir.display());
    let t2 = format!("{}/wavelink_gapless_t2.wav", dir.display());

    const N1: usize = 4410; // 0.1s
    const N2: usize = 8820; // 0.2s
    write_constant_wav(&t1, 0.25, N1);
    write_constant_wav(&t2, -0.25, N2);

    let out = capture_chained_output(&t1, &t2);

    // ① 总样本数精确 = 两首之和（2 声道）。
    //    gap（插入静音）→ 偏多；overlap（重复）→ 偏多；loss → 偏少。
    let expected = (N1 + N2) * 2;
    assert_eq!(
        out.len(),
        expected,
        "无缝衔接总样本数应精确等于两首之和：期望 {expected}，实际 {}（差异暗示 gap/overlap/loss）",
        out.len()
    );

    // ② 全程无零样本：两首都是非零恒定电平，任何 0 都意味着插入了静音 gap
    let zero_count = out.iter().filter(|&&s| s == 0.0).count();
    assert_eq!(
        zero_count, 0,
        "恒定电平曲目衔接后不应出现零样本（发现 {zero_count} 个），有零即存在 gap"
    );

    // ③ 衔接处值正确且跳变锐利：
    //    track1 最后一帧 ≈ +0.25，track2 第一帧 ≈ -0.25，中间无过渡样本
    let junction = N1 * 2; // track1 结束处的样本下标（立体声）
    let last_of_t1 = out[junction - 1];
    let first_of_t2 = out[junction];
    assert!(
        (last_of_t1 - 0.25).abs() < 0.001,
        "track1 末样本应 ≈ +0.25，实际 {last_of_t1}"
    );
    assert!(
        (first_of_t2 + 0.25).abs() < 0.001,
        "track2 首样本应 ≈ -0.25，实际 {first_of_t2}"
    );

    // ④ 两段内部电平稳定（无错位/串扰）
    let t1_mean: f32 = out[..junction].iter().sum::<f32>() / junction as f32;
    let t2_mean: f32 = out[junction..].iter().sum::<f32>() / (out.len() - junction) as f32;
    assert!(
        (t1_mean - 0.25).abs() < 0.001,
        "track1 段均值应 ≈ +0.25，实际 {t1_mean}"
    );
    assert!(
        (t2_mean + 0.25).abs() < 0.001,
        "track2 段均值应 ≈ -0.25，实际 {t2_mean}"
    );

    let _ = std::fs::remove_file(&t1);
    let _ = std::fs::remove_file(&t2);
}

/// 三首连续衔接（A→B→C）也应全程无缝，验证 on_end_of_track 多次链接不退化。
/// 用三种不同电平区分各段，断言总样本数精确 + 各段均值正确。
#[test]
fn gapless_three_track_chain() {
    let dir = std::env::temp_dir();
    let ta = format!("{}/wavelink_gapless_a.wav", dir.display());
    let tb = format!("{}/wavelink_gapless_b.wav", dir.display());
    let tc = format!("{}/wavelink_gapless_c.wav", dir.display());

    const NA: usize = 2000;
    const NB: usize = 3000;
    const NC: usize = 2500;
    write_constant_wav(&ta, 0.20, NA);
    write_constant_wav(&tb, -0.30, NB);
    write_constant_wav(&tc, 0.40, NC);

    // 链接 A→B→C：用队列依次提供后续 rx
    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx_a, _da) =
        Decoder::start(std::path::Path::new(&ta), 44100, 2, pos.clone(), None, None).unwrap();
    let (rx_b, _db) =
        Decoder::start(std::path::Path::new(&tb), 44100, 2, pos.clone(), None, None).unwrap();
    let (rx_c, _dc) =
        Decoder::start(std::path::Path::new(&tc), 44100, 2, pos.clone(), None, None).unwrap();

    let queue = Arc::new(Mutex::new(vec![rx_b, rx_c]));
    let q = queue.clone();
    let captured = Arc::new(Mutex::new(Vec::new()));
    let cap = captured.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0,
        recv_timeout_ms: 500,
        passthrough: false,
    };

    let handle = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| {
                cap.lock().extend_from_slice(buf);
                buf.len()
            },
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| {
                let mut g = q.lock();
                if g.is_empty() {
                    None
                } else {
                    Some(g.remove(0))
                }
            },
        };
        let ctrl = ConsumerControl {
            stop: s,
            ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx_a, &config, &cb, &ctrl);
        drop((_da, _db, _dc));
    });

    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("consumer 应就绪");
    handle.join().expect("consumer 线程不应 panic");

    let out = captured.lock().clone();
    let expected = (NA + NB + NC) * 2;
    assert_eq!(
        out.len(),
        expected,
        "三首链接总样本数应精确：期望 {expected}，实际 {}",
        out.len()
    );

    // 各段均值正确（验证无错位/串扰）
    let ja = NA * 2;
    let jb = (NA + NB) * 2;
    let mean = |r: std::ops::Range<usize>| out[r].iter().sum::<f32>() / (jb - ja) as f32;
    let ma = out[..ja].iter().sum::<f32>() / ja as f32;
    let mb = mean(ja..jb);
    let mc = out[jb..].iter().sum::<f32>() / (out.len() - jb) as f32;
    assert!((ma - 0.20).abs() < 0.001, "A 段均值应 ≈ +0.20，实际 {ma}");
    assert!((mb + 0.30).abs() < 0.001, "B 段均值应 ≈ -0.30，实际 {mb}");
    assert!((mc - 0.40).abs() < 0.001, "C 段均值应 ≈ +0.40，实际 {mc}");

    let _ = std::fs::remove_file(&ta);
    let _ = std::fs::remove_file(&tb);
    let _ = std::fs::remove_file(&tc);
}
