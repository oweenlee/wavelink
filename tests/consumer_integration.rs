//! consumer.rs 集成测试：用真实 Decoder 喂帧，验证完整链路
//!
//! 测试内容：
//! - 真实解码帧经过 consumer 循环处理后正确输出
//! - 不同格式/采样率的解码帧不走样
//! - consumer 配置（recv_timeout / fft_interval）不影响输出完整性

mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use parking_lot::Mutex;
use std::thread;
use std::time::Duration;

use audio_core::consumer::{run_consumer_loop, ConsumerConfig};
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
        run_consumer_loop(
            rx,
            &config,
            &|buf| {
                *tp.lock() += buf.len();
                buf.len()
            },
            &|_| {},
            &|_| {},
            &|| {},
            &|_| {},
            &|| None,
            &s,
            ready_tx,
            Arc::new(Mutex::new(1.0f32)),
        );
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
        total >= 176_000 && total <= 177_000,
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
        run_consumer_loop(
            rx,
            &config,
            &|buf| buf.len(),
            &|_| {},
            &|_| {},
            &|| {},
            &|n| {
                *oc.lock() += n;
            },
            &|| None,
            &s,
            ready_tx,
            Arc::new(Mutex::new(1.0f32)),
        );
    });

    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("ready");

    consumer_h.join().expect("consumer join");

    let reported = *output_count.lock();
    eprintln!("on_samples_output total: {reported}");
    assert!(
        reported >= 176_000 && reported <= 177_000,
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
        run_consumer_loop(
            rx,
            &config,
            &|buf| {
                *tp.lock() += buf.len();
                buf.len()
            },
            &|_| {},
            &|_| {},
            &|| {},
            &|_| {},
            &|| None,
            &s,
            ready_tx,
            Arc::new(Mutex::new(1.0f32)),
        );
    });

    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("ready");

    consumer_h.join().expect("consumer join");

    let total = *total_pushed.lock();
    eprintln!("48kHz WAV 2s consumer total samples: {total}");

    // 48kHz 2s 立体声 → 192000 样本（rubato 重采样到 48kHz = 无重采样）
    assert!(
        total >= 191_000 && total <= 193_000,
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
        run_consumer_loop(
            rx,
            &config,
            &|_| 0,
            &|_| {},
            &|_| {},
            &|| {},
            &|_| {},
            &|| None,
            &s,
            ready_tx,
            Arc::new(Mutex::new(1.0f32)),
        );
    });

    ready_rx.recv_timeout(Duration::from_secs(5)).expect("ready");
    stop.store(true, Ordering::SeqCst);

    // 应该快速退出
    let ok = consumer_h.join().is_ok();
    assert!(ok, "在真实解码中设置 stop flag 也应该退出");
}
