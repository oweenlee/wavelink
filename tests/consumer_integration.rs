//! consumer.rs 集成测试：用真实 Decoder 喂帧，验证完整链路
//!
//! 测试内容：
//! - 真实解码帧经过 consumer 循环处理后正确输出
//! - 不同格式/采样率的解码帧不走样
//! - consumer 配置（recv_timeout / fft_interval）不影响输出完整性

mod common;

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use parking_lot::Mutex;
use std::thread;
use std::time::Duration;

use audio_core::consumer::{run_consumer_loop, ConsumerCallbacks, ConsumerConfig, ConsumerControl};
use audio_core::decoder::Decoder;
use crossbeam_channel::bounded;

/// 测试真实解码→consumer 链路：解码一首歌，过 consumer，验证总样本数正确
#[test]
fn test_real_wav_through_consumer() {
    let a = common::ensure_fixtures();
    let path = a.wav.clone(); // 44100Hz, 2ch, 2s → 176400 samples

    // 启动解码器
    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) = Decoder::start(
        std::path::Path::new(&path),
        44100, 2, pos, None, None,
    )
    .expect("Decoder::start 失败");

    let total_pushed = Arc::new(Mutex::new(0usize));
    let tp = total_pushed.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0,
        recv_timeout_ms: 500,
    };

    let consumer_h = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| {
                *tp.lock() += buf.len();
                buf.len()
            },
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    // 等待 ready
    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("consumer 应在 5s 内就绪");

    // 等待解码完成
    consumer_h.join().expect("consumer 线程不应 panic");

    let total = *total_pushed.lock();
    eprintln!("WAV 2s consumer total samples: {total}");

    // test_wav_48k 中 44.1k 2s 立体声 = 176400 样本，这里也接近
    assert!(
        (176_000..=177_000).contains(&total),
        "WAV 2s @44100/2ch 应产生 ~176400 样本, got {total}"
    );
}

/// 测试 consumer 在收到足够多帧后正确调用 on_samples_output
#[test]
fn test_consumer_output_count_matches() {
    let a = common::ensure_fixtures();
    let path = a.wav.clone();

    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) =
        Decoder::start(std::path::Path::new(&path), 44100, 2, pos, None, None).expect("Decoder::start");

    let output_count = Arc::new(Mutex::new(0u64));
    let oc = output_count.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0,
        recv_timeout_ms: 500,
    };

    let consumer_h = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| buf.len(),
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|n| {
                *oc.lock() += n;
            },
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("ready");

    consumer_h.join().expect("consumer join");

    let reported = *output_count.lock();
    eprintln!("on_samples_output total: {reported}");
    assert!(
        (176_000..=177_000).contains(&reported),
        "on_samples_output 应报告 ~176400, got {reported}"
    );
}

/// 测试 48kHz WAV：consumer 传输时不会丢帧或吞帧
#[test]
fn test_48k_wav_through_consumer() {
    let a = common::ensure_fixtures();
    let path = a.wav_48k.clone(); // 48000Hz, 2ch, 2s → 192000 samples

    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) =
        Decoder::start(std::path::Path::new(&path), 48000, 2, pos, None, None).expect("Decoder::start");

    let total_pushed = Arc::new(Mutex::new(0usize));
    let tp = total_pushed.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 48000,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0,
        recv_timeout_ms: 500,
    };

    let consumer_h = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| {
                *tp.lock() += buf.len();
                buf.len()
            },
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("ready");

    consumer_h.join().expect("consumer join");

    let total = *total_pushed.lock();
    eprintln!("48kHz WAV 2s consumer total samples: {total}");

    // 48kHz 2s 立体声 → 192000 样本（rubato 重采样到 48kHz = 无重采样）
    assert!(
        (191_000..=193_000).contains(&total),
        "48kHz WAV 2s 应产生 ~192000 样本, got {total}"
    );
}

/// 测试 consumer 的 stop flag 在真实解码情况下也能快速中止
#[test]
fn test_consumer_stop_during_decoding() {
    let a = common::ensure_fixtures();
    let path = a.wav.clone();

    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) =
        Decoder::start(std::path::Path::new(&path), 44100, 2, pos, None, None).expect("Decoder::start");

    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0,
        recv_timeout_ms: 100, // 快速检查 stop
    };

    let consumer_h = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|_| 0,
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    ready_rx.recv_timeout(Duration::from_secs(5)).expect("ready");
    stop.store(true, Ordering::SeqCst);

    // 应该快速退出
    let ok = consumer_h.join().is_ok();
    assert!(ok, "在真实解码中设置 stop flag 也应该退出");
}

// ── 极端场景补充 ──

/// 验证 recv_timeout_ms=0（忙轮询模式）不 panic
#[test]
fn test_consumer_zero_timeout() {
    let a = common::ensure_fixtures();
    let path = a.wav.clone();

    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) =
        Decoder::start(std::path::Path::new(&path), 44100, 2, pos, None, None).expect("Decoder::start");

    let total_pushed = Arc::new(Mutex::new(0usize));
    let tp = total_pushed.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100,
        channels: 2,
        fft_interval: 3,
        crossfade_ms: 0,
        recv_timeout_ms: 0, // 忙轮询
    };

    let consumer_h = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| { *tp.lock() += buf.len(); buf.len() },
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    ready_rx.recv_timeout(Duration::from_secs(5)).expect("consumer ready");
    consumer_h.join().expect("consumer 不应 panic");

    let total = *total_pushed.lock();
    assert!(total > 0, "recv_timeout_ms=0 下仍有样本输出");
}

/// 极短音频文件（~10ms）通过 consumer 不 panic
#[test]
fn test_consumer_very_short_file() {
    let path = "/tmp/_consumer_very_short.wav";
    {
        let spec = hound::WavSpec {
            channels: 2, sample_rate: 44100, bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        let n = (44100.0 * 0.01) as u32 * 2; // 10ms 立体声
        for i in 0..n {
            let t = i as f64 / 44100.0;
            let s = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.5;
            writer.write_sample((s * i16::MAX as f64) as i16).unwrap();
        }
        writer.finalize().unwrap();
    }

    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) =
        Decoder::start(std::path::Path::new(path), 44100, 2, pos, None, None).expect("Decoder::start");

    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100, channels: 2, fft_interval: 3,
        crossfade_ms: 0, recv_timeout_ms: 200,
    };

    let total = Arc::new(Mutex::new(0usize));
    let total_clone = total.clone();
    let consumer_h = thread::spawn(move || {
        let cb = ConsumerCallbacks {
            push_samples: &|buf| { *total_clone.lock() += buf.len(); buf.len() },
            process_dsp: &|_| {},
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    ready_rx.recv_timeout(Duration::from_secs(5)).expect("consumer ready");
    let ok = consumer_h.join().is_ok();
    assert!(ok, "极短文件 consumer 不应 panic");
    let total_out = *total.lock();
    assert!(total_out > 0, "极短文件应产生输出样本");
    let _ = std::fs::remove_file(path);
}

/// 静音 DSP 管线（process_dsp 设全零）时 consumer 正常结束
#[test]
fn test_consumer_dsp_silences_output() {
    let a = common::ensure_fixtures();
    let path = a.wav.clone();

    let pos = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let (rx, _dec) =
        Decoder::start(std::path::Path::new(&path), 44100, 2, pos, None, None).expect("Decoder::start");

    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = bounded(1);

    let config = ConsumerConfig {
        sample_rate: 44100, channels: 2, fft_interval: 3,
        crossfade_ms: 0, recv_timeout_ms: 200,
    };

    let consumer_h = thread::spawn(move || {
        // process_dsp 将样本全设 0（模拟静音输出）
        let cb = ConsumerCallbacks {
            push_samples: &|buf| { buf.len() },
            process_dsp: &|buf: &mut [f32]| { for s in buf.iter_mut() { *s = 0.0; } },
            on_spectrum: &|_| {},
            on_bad_frame: &|| {},
            on_samples_output: &|_| {},
            on_end_of_track: &|| None,
        };
        let ctrl = ConsumerControl {
            stop: s, ready_tx,
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        };
        run_consumer_loop(rx, &config, &cb, &ctrl);
    });

    ready_rx.recv_timeout(Duration::from_secs(5)).expect("consumer ready");
    // stop flag 无需设置，解码完成后 consumer 自动退出
    let ok = consumer_h.join().is_ok();
    assert!(ok, "DSP 静音处理时 consumer 不应 panic");
}
