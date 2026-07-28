//! 平台无关的解码→DSP→ringbuf 循环。
//!
//! 这里是 PC `spawn_consumer` 和 Mobile `run_decoder` 的共享内核。
//! 两边只需传入各自的闭包（写 ringbuf、过 DSP、报频谱等），
//! 不再各自维护一套解码循环。
//!
//! 使用方式见 `run_consumer_loop()` 的文档。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, RecvTimeoutError};
use parking_lot::Mutex;
use realfft::num_complex::Complex;
use realfft::RealFftPlanner;

use crate::decoder::DecodedFrame;
use crate::dsp::speed::SpeedChanger;

/// 频谱频段数
pub const SPECTRUM_BANDS: usize = 16;

/// 循环配置
pub struct ConsumerConfig {
    /// 输出采样率
    pub sample_rate: u32,
    /// 声道数
    pub channels: u32,
    /// 每 N 帧做一次频谱 FFT（PC=3, Mobile=4）
    pub fft_interval: u32,
    /// 切歌淡入时长（毫秒），0 = 无淡入。仅 PC 用，Mobile 保持 0
    pub crossfade_ms: u32,
    /// 解码帧接收超时（毫秒）
    pub recv_timeout_ms: u64,
}

impl Default for ConsumerConfig {
    fn default() -> Self {
        ConsumerConfig {
            sample_rate: 44100,
            channels: 2,
            fft_interval: 3,
            crossfade_ms: 0,
            recv_timeout_ms: 500,
        }
    }
}

/// 平台无关的解码消费循环。
///
/// 从 `rx` 接收解码帧，依次过 `process_dsp`、可选 crossfade、坏帧检测、`push_samples`。
/// 每 `fft_interval` 帧计算一次频谱，通过 `on_spectrum` 回调。
/// 当 `rx` 断开（曲目播完）时调 `on_end_of_track`：返回新的 rx 继续循环，返回 None 退出。
///
/// # 参数
/// - `rx` — 解码帧接收器
/// - `config` — 采样率、声道数、FFT 间隔、crossfade 等配置
/// - `push_samples` — 将处理后的样本写入 ringbuf，返回实际写入的样本数
/// - `process_dsp` — 过 DSP 管线，原地修改样本
/// - `on_spectrum` — 16 频段频谱回调，每 `fft_interval` 帧调用一次
/// - `on_bad_frame` — 检测到坏帧时回调（全零/NaN）
/// - `on_samples_output` — 每帧输出后回调，参数为输出样本数（用于进度追踪）
/// - `on_end_of_track` — 当前解码器结束时回调，返回新解码器可无缝切歌
/// - `stop` — 停止信号，设 true 后循环尽快退出
/// - `ready_tx` — 首帧就绪时发送 true，通知播放器可以起播
/// - `speed` — 共享播放速度（0.25 ~ 4.0），设 1.0 不变速
pub fn run_consumer_loop(
    rx: Receiver<DecodedFrame>,
    config: &ConsumerConfig,
    push_samples: &dyn Fn(&[f32]) -> usize,
    process_dsp: &dyn Fn(&mut [f32]),
    on_spectrum: &dyn Fn(&[f32; SPECTRUM_BANDS]),
    on_bad_frame: &dyn Fn(),
    on_samples_output: &dyn Fn(u64),
    on_end_of_track: &dyn Fn() -> Option<Receiver<DecodedFrame>>,
    stop: &AtomicBool,
    ready_tx: Sender<bool>,
    speed: Arc<Mutex<f32>>,
) {
    // 线程优先级由调用方（engine.rs / audio_output.rs）在 spawn 前设置

    // ── 频谱 FFT 初始化 ──
    let fft_size = 1024usize;
    let mut planner = RealFftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(fft_size);
    let mut hann = vec![0.0f32; fft_size];
    for i in 0..fft_size {
        let angle = 2.0 * std::f32::consts::PI * i as f32 / (fft_size - 1) as f32;
        hann[i] = 0.5 * (1.0 - angle.cos());
    }
    let mut fft_input = vec![0.0f32; fft_size];
    let mut fft_out = vec![Complex::new(0.0f32, 0.0f32); fft_size / 2 + 1];
    let freq_per_bin = config.sample_rate as f32 / fft_size as f32;
    // 与 PC 一致的频段划分
    let band_edges: [f32; SPECTRUM_BANDS] = [
        120.0, 200.0, 300.0, 450.0, 650.0, 900.0, 1200.0, 1600.0,
        2200.0, 3200.0, 4600.0, 6400.0, 8800.0, 12000.0, 16000.0, 22050.0,
    ];
    let mut bin_to_band = vec![0usize; fft_size / 2];
    for bin in 0..fft_size / 2 {
        let freq = bin as f32 * freq_per_bin;
        if freq < 20.0 {
            bin_to_band[bin] = 0;
            continue;
        }
        let mut band = SPECTRUM_BANDS - 1;
        for (b, &edge) in band_edges.iter().enumerate() {
            if freq < edge {
                band = b;
                break;
            }
        }
        bin_to_band[bin] = band;
    }

    // 峰值跟踪状态
    let mut band_peaks = vec![0.001f32; SPECTRUM_BANDS];
    let mut frame_count: u64 = 0;
    let mut first_frame = true;
    let ch = config.channels as usize;

    // Crossfade 状态
    let fade_total = if config.crossfade_ms > 0 && config.sample_rate > 0 {
        (config.sample_rate as f64 * config.crossfade_ms as f64 / 1000.0) as usize * ch
    } else {
        0
    };
    let mut fade_remaining: usize = 0;

    // 变速重采样器
    let mut speed_changer = SpeedChanger::new();

    let timeout = Duration::from_millis(config.recv_timeout_ms);
    let mut current_rx = rx;

    loop {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        match current_rx.recv_timeout(timeout) {
            Ok(frame) => {
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                if first_frame {
                    let _ = ready_tx.send(true);
                    first_frame = false;
                    // 首帧触发 crossfade
                    fade_remaining = fade_total;
                }
                frame_count += 1;
                let count = frame.samples.len() as u64;
                let mut buf = frame.samples;

                // 1) DSP 处理
                process_dsp(&mut buf);

                // 2) 实时频谱
                if frame_count % config.fft_interval as u64 == 0 && buf.len() >= fft_size * ch {
                    for i in 0..fft_size {
                        let l = buf[i * ch];
                        let r = if ch >= 2 { buf[i * ch + 1] } else { l };
                        fft_input[i] = (l + r) * 0.5 * hann[i];
                    }
                    if fft.process(&mut fft_input, &mut fft_out).is_ok() {
                        let mut bands = [0.0f32; SPECTRUM_BANDS];
                        let mut band_counts = [0usize; SPECTRUM_BANDS];
                        for (bin, &c) in fft_out.iter().enumerate().skip(1) {
                            if bin >= bin_to_band.len() {
                                break;
                            }
                            let b = bin_to_band[bin];
                            bands[b] += c.norm_sqr().sqrt();
                            band_counts[b] += 1;
                        }
                        for b in 0..SPECTRUM_BANDS {
                            if band_counts[b] > 0 {
                                let avg = bands[b] / band_counts[b] as f32;
                                let peak = band_peaks[b];
                                band_peaks[b] = if avg > peak {
                                    avg * 1.1
                                } else {
                                    peak * 0.93
                                };
                                bands[b] = (avg / band_peaks[b].max(0.001)).min(1.0);
                            } else {
                                band_peaks[b] *= 0.90;
                            }
                        }
                        on_spectrum(&bands);
                    }
                }

                // 3) 坏帧检测（在淡入之前，避免淡入把首帧压到接近零被误判）
                if buf.iter().all(|&s| s == 0.0) || buf.iter().any(|&s| !s.is_finite()) {
                    on_bad_frame();
                    continue;
                }

                // 4) 余弦淡入
                if fade_remaining > 0 {
                    let n = fade_remaining.min(buf.len());
                    let done = fade_total - fade_remaining;
                    for i in 0..n {
                        let gain = (1.0
                            - ((done + i) as f32 / fade_total as f32 * std::f32::consts::PI).cos())
                            / 2.0;
                        buf[i] *= gain;
                    }
                    fade_remaining -= n;
                }

                // 5) 变速重采样
                let output_buf = {
                    let sp = *speed.lock();
                    if (sp - 1.0).abs() > 0.001 {
                        speed_changer.set_speed(sp);
                        let out = speed_changer.process(&buf, ch);
                        if out.is_empty() { &buf } else { out }
                    } else {
                        &buf
                    }
                };

                // 6) 推入 ringbuf（ringbuf 无阻塞 API，满时短暂让出 CPU）
                let mut remaining: &[f32] = output_buf;
                let mut spin_count = 0u32;
                while !remaining.is_empty() && !stop.load(Ordering::SeqCst) {
                    let n = push_samples(remaining);
                    if n == 0 {
                        // 先 spin 几次，避免 sleep 导致 underrun；连续满才 yield
                        spin_count += 1;
                        if spin_count < 64 {
                            std::hint::spin_loop();
                        } else {
                            std::thread::yield_now();
                            spin_count = 0;
                        }
                    } else {
                        spin_count = 0;
                    }
                    remaining = &remaining[n..];
                }

                // 7) 进度追踪（使用原始解码样本数，追踪源音频位置）
                on_samples_output(count);
            }
            Err(RecvTimeoutError::Timeout) => {
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => {
                // 解码器 channel 断开 → 曲目播完
                if let Some(new_rx) = on_end_of_track() {
                    current_rx = new_rx;
                    // 无缝切歌时重置淡入
                    fade_remaining = fade_total;
                    continue;
                }
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use parking_lot::Mutex as PlMutex;
    use std::thread;
    use crossbeam_channel::{bounded, unbounded};

    fn make_frame(samples: Vec<f32>) -> DecodedFrame {
        DecodedFrame {
            samples,
            sample_rate: 44100,
            channels: 2,
            pts_secs: 0.0,
        }
    }

    fn default_config() -> ConsumerConfig {
        ConsumerConfig {
            sample_rate: 44100,
            channels: 2,
            fft_interval: 3,
            crossfade_ms: 0,
            recv_timeout_ms: 100,
        }
    }

    /// 在后台线程跑 consumer loop，返回(handle, stop, ready_rx)
    /// 所有闭包在 thread::spawn 内部创建，避免 dyn Fn 不是 Sync 的问题
    fn spawn_consumer<E>(
        rx: Receiver<DecodedFrame>,
        config: ConsumerConfig,
        push_fn: E,
    ) -> (thread::JoinHandle<()>, Arc<AtomicBool>, Receiver<bool>)
    where
        E: Fn(&[f32]) -> usize + Send + 'static,
    {
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let speed = Arc::new(PlMutex::new(1.0f32));
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &push_fn;
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nobad = &|| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &config,
                push, passthrough, nospec, nobad, nooutput, noeot,
                &s, ready_tx, speed,
            );
        });
        (handle, stop, ready_rx)
    }

    #[test]
    fn test_ready_handshake() {
        let (tx, rx) = unbounded();
        let (handle, _, ready_rx) = spawn_consumer(rx, default_config(), |s| s.len());
        tx.send(make_frame(vec![0.5; 256])).unwrap();
        let ok = ready_rx.recv_timeout(Duration::from_secs(3)).is_ok();
        assert!(ok, "ready signal should be sent");
        drop(tx);
        handle.join().unwrap();
    }

    #[test]
    fn test_bad_frame_all_zero_skipped() {
        let (tx, rx) = unbounded();
        let bad = Arc::new(Mutex::new(false));
        let pushed = Arc::new(Mutex::new(0usize));
        let b = bad.clone();
        let p = pushed.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| { *p.lock().unwrap() += s.len(); s.len() };
            let on_bad = &|| { *b.lock().unwrap() = true; };
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &default_config(),
                push, passthrough, nospec, on_bad, nooutput, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        tx.send(make_frame(vec![0.0; 256])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        thread::sleep(Duration::from_millis(50));
        drop(tx);
        handle.join().unwrap();

        assert!(*bad.lock().unwrap(), "on_bad_frame should be called for all-zero");
        assert_eq!(*pushed.lock().unwrap(), 0, "bad frame should not be pushed");
    }

    #[test]
    fn test_nan_frame_skipped() {
        let (tx, rx) = unbounded();
        let bad = Arc::new(Mutex::new(false));
        let pushed = Arc::new(Mutex::new(0usize));
        let b = bad.clone();
        let p = pushed.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| { *p.lock().unwrap() += s.len(); s.len() };
            let on_bad = &|| { *b.lock().unwrap() = true; };
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &default_config(),
                push, passthrough, nospec, on_bad, nooutput, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        tx.send(make_frame(vec![f32::NAN; 256])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        thread::sleep(Duration::from_millis(50));
        drop(tx);
        handle.join().unwrap();

        assert!(*bad.lock().unwrap(), "on_bad_frame should be called for NaN");
        assert_eq!(*pushed.lock().unwrap(), 0, "NaN frame should not be pushed");
    }

    #[test]
    fn test_stop_flag_exits() {
        let (tx, rx) = unbounded();
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let mut cfg = default_config();
        cfg.recv_timeout_ms = 20;
        let (ready_tx, ready_rx) = bounded(1);

        let handle = thread::spawn(move || {
            let push = &|_: &[f32]| 0;
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nobad = &|| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &cfg,
                push, passthrough, nospec, nobad, nooutput, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        tx.send(make_frame(vec![0.5; 256])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        stop.store(true, Ordering::SeqCst);
        let ok = handle.join().is_ok();
        assert!(ok, "consumer loop should exit on stop flag");
    }

    #[test]
    fn test_crossfade_attenuates_first_frame() {
        let (tx, rx) = unbounded();
        let pushed = Arc::new(Mutex::new(Vec::new()));
        let p = pushed.clone();
        let mut cfg = default_config();
        cfg.crossfade_ms = 100;
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);

        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| { p.lock().unwrap().extend_from_slice(s); s.len() };
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nobad = &|| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &cfg,
                push, passthrough, nospec, nobad, nooutput, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        let n = (44100.0 * 0.2) as usize * 2; // ~17640 samples
        tx.send(make_frame(vec![1.0; n])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        thread::sleep(Duration::from_millis(200));
        drop(tx);
        handle.join().unwrap();

        let buf = pushed.lock().unwrap();
        assert!(
            buf[0].abs() < 0.02,
            "first sample should be near 0 (cosine fade), got {}",
            buf[0]
        );
        let fade_samples = (44100.0 * 0.1) as usize * 2;
        assert!(
            (buf[fade_samples - 1] - 1.0).abs() < 0.02,
            "sample at fade boundary should be near 1.0, got {}",
            buf[fade_samples - 1]
        );
        assert!(
            (buf[fade_samples] - 1.0).abs() < 0.001,
            "sample after fade should be exactly 1.0, got {}",
            buf[fade_samples]
        );
    }

    #[test]
    fn test_on_end_of_track_chain() {
        let (tx, rx) = unbounded();
        let (tx2, rx2) = unbounded();
        let frame_count = Arc::new(Mutex::new(0u64));
        let fc = frame_count.clone();

        // rx2 放在 Mutex<Option<>> 里，Fn 闭包可多次调 take()
        let next_rx = Arc::new(Mutex::new(Some(rx2)));
        let nr = next_rx.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| s.len();
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nobad = &|| {};
            let on_output = &|n: u64| { *fc.lock().unwrap() += 1; let _ = n; };
            let on_eot = &|| -> Option<Receiver<DecodedFrame>> { nr.lock().unwrap().take() };
            run_consumer_loop(
                rx, &default_config(),
                push, passthrough, nospec, nobad, on_output, on_eot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        tx.send(make_frame(vec![0.5; 256])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        drop(tx);
        thread::sleep(Duration::from_millis(50));

        tx2.send(make_frame(vec![0.5; 256])).unwrap();
        thread::sleep(Duration::from_millis(50));
        drop(tx2);
        handle.join().unwrap();

        assert_eq!(
            *frame_count.lock().unwrap(),
            2,
            "should process 2 frames across chained decoders"
        );
    }

    #[test]
    fn test_on_end_of_track_exit_on_none() {
        let (tx, rx) = unbounded();
        // 用 |s| s.len() 而非 |_| 0，避免 push 无限循环
        let (handle, _, ready_rx) = spawn_consumer(rx, default_config(), |s| s.len());
        tx.send(make_frame(vec![0.5; 256])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        drop(tx);
        let ok = handle.join().is_ok();
        assert!(ok, "should exit when on_end_of_track returns None");
    }

    #[test]
    fn test_spectrum_computed_at_interval() {
        let (tx, rx) = unbounded();
        let spectrum_count = Arc::new(Mutex::new(0u64));
        let sc = spectrum_count.clone();
        let mut cfg = default_config();
        cfg.fft_interval = 2;

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| s.len();
            let passthrough = &|_: &mut [f32]| {};
            let on_spec = &|_: &[f32; SPECTRUM_BANDS]| { *sc.lock().unwrap() += 1; };
            let nobad = &|| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &cfg,
                push, passthrough, on_spec, nobad, nooutput, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        for _ in 0..6 {
            tx.send(make_frame(vec![0.5; 4096])).unwrap();
        }
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        thread::sleep(Duration::from_millis(200));
        drop(tx);
        handle.join().unwrap();

        let count = *spectrum_count.lock().unwrap();
        assert!(
            count >= 2,
            "spectrum callback should be called multiple times (fft_interval=2), got {}",
            count
        );
    }

    #[test]
    fn test_samples_output_tracked() {
        let (tx, rx) = unbounded();
        let total_samples = Arc::new(Mutex::new(0u64));
        let ts = total_samples.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| s.len();
            let passthrough = &|_: &mut [f32]| {};
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nobad = &|| {};
            let on_output = &|n: u64| { *ts.lock().unwrap() += n; };
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &default_config(),
                push, passthrough, nospec, nobad, on_output, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        tx.send(make_frame(vec![0.5; 256])).unwrap();
        tx.send(make_frame(vec![0.5; 512])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        thread::sleep(Duration::from_millis(100));
        drop(tx);
        handle.join().unwrap();

        let total = *total_samples.lock().unwrap();
        assert_eq!(total, 768, "on_samples_output should sum sample counts: got {}", total);
    }

    #[test]
    fn test_dsp_processes_samples_in_place() {
        let (tx, rx) = unbounded();
        let processed = Arc::new(Mutex::new(Vec::new()));
        let p = processed.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let push = &|s: &[f32]| s.len();
            let dsp = &mut |buf: &mut [f32]| {
                for sample in buf.iter_mut() {
                    *sample *= 2.0;
                }
                p.lock().unwrap().extend_from_slice(buf);
            };
            let nospec = &|_: &[f32; SPECTRUM_BANDS]| {};
            let nobad = &|| {};
            let nooutput = &|_: u64| {};
            let noeot = &|| -> Option<Receiver<DecodedFrame>> { None };
            run_consumer_loop(
                rx, &default_config(),
                push, dsp, nospec, nobad, nooutput, noeot,
                &s, ready_tx, Arc::new(PlMutex::new(1.0f32)),
            );
        });

        tx.send(make_frame(vec![1.0; 128])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        thread::sleep(Duration::from_millis(50));
        drop(tx);
        handle.join().unwrap();

        let buf = processed.lock().unwrap();
        assert_eq!(buf.len(), 128, "DSP should process all samples");
        assert!(
            (buf[0] - 2.0).abs() < 0.001,
            "DSP should double samples: got {}",
            buf[0]
        );
    }
}
