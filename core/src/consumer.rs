//! 平台无关的解码→DSP→ringbuf 循环。
//!
//! 这里是 PC `spawn_consumer` 和 Mobile `run_decoder` 的共享内核。
//! 两边只需传入各自的闭包（写 ringbuf、过 DSP、报频谱等），
//! 不再各自维护一套解码循环。
//!
//! 使用方式见 `run_consumer_loop()` 的文档。

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
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
    /// 直通模式（DoP 直出用）：跳过 DSP/频谱/淡入/变速/坏帧检测，
    /// 解码帧逐比特原样推入 ringbuf。
    pub passthrough: bool,
}

impl Default for ConsumerConfig {
    fn default() -> Self {
        ConsumerConfig {
            sample_rate: 44100,
            channels: 2,
            fft_interval: 3,
            crossfade_ms: 0,
            recv_timeout_ms: 500,
            passthrough: false,
        }
    }
}

/// 消费者循环回调集合
pub struct ConsumerCallbacks<'a> {
    /// 将处理后的样本写入 ringbuf，返回实际写入的样本数
    pub push_samples: &'a dyn Fn(&[f32]) -> usize,
    /// 过 DSP 管线，原地修改样本
    pub process_dsp: &'a dyn Fn(&mut [f32]),
    /// 16 频段频谱回调，每 `fft_interval` 帧调用一次
    pub on_spectrum: &'a dyn Fn(&[f32; SPECTRUM_BANDS]),
    /// 检测到坏帧时回调（全零/NaN）
    pub on_bad_frame: &'a dyn Fn(),
    /// 每帧输出后回调，参数为输出样本数（用于进度追踪）
    pub on_samples_output: &'a dyn Fn(u64),
    /// 当前解码器结束时回调，返回新解码器可无缝切歌
    pub on_end_of_track: &'a dyn Fn() -> Option<Receiver<DecodedFrame>>,
    /// 真交叉淡化：取走预加载的下一首接收端（无预加载时返回 None）。
    /// 与 on_end_of_track 的区别：不发送切歌事件（旧曲尾部还在播，
    /// 事件由 on_crossfaded 在混合完成时补发）
    pub take_next_rx: &'a dyn Fn() -> Option<Receiver<DecodedFrame>>,
    /// 真交叉淡化混合完成（旧曲已耗尽）：等价 on_end_of_track 的事件部分，
    /// 不再取下一首（已在 take_next_rx 取过）
    pub on_crossfaded: &'a dyn Fn(),
}

/// 消费者循环控制信号
pub struct ConsumerControl {
    /// 停止信号，设 true 后循环尽快退出
    pub stop: Arc<AtomicBool>,
    /// 首帧就绪时发送 true，通知播放器可以起播
    pub ready_tx: Sender<bool>,
    /// 共享播放速度（0.25 ~ 4.0），设 1.0 不变速
    pub speed: Arc<AtomicU32>,
    /// 真交叉淡化触发：引擎线程在播放位置进入淡变窗口（距曲尾 crossfade_ms）
    /// 时置 true；消费者取预加载下一首做双源混合。未启用时为永不置位的哑标志。
    pub xfade_trigger: Arc<AtomicBool>,
}

/// ringbuf 满时的写入退避：先短暂 spin 抗抖动，随后逐级 sleep。
/// 输出停摆（如 AVAudioEngine 被系统停止）时若只 yield_now 会变成
/// 100% CPU 死循环，触发 iOS cpu_resource 看门狗杀进程。
fn push_with_backoff(mut remaining: &[f32], push: &dyn Fn(&[f32]) -> usize, stop: &AtomicBool) {
    let mut spin_count = 0u32;
    let mut stalled = 0u32;
    while !remaining.is_empty() && !stop.load(Ordering::SeqCst) {
        let n = push(remaining);
        if n == 0 {
            spin_count += 1;
            if spin_count < 64 {
                std::hint::spin_loop();
            } else if stalled < 50 {
                stalled += 1;
                std::thread::sleep(Duration::from_millis(1));
            } else {
                std::thread::sleep(Duration::from_millis(10));
            }
        } else {
            spin_count = 0;
            stalled = 0;
        }
        remaining = &remaining[n..];
    }
}

/// 真交叉淡化结果
enum CrossfadeOutcome {
    /// 混合完成（旧曲尾部耗尽或淡变窗口走完）：新曲接管播放。
    /// leftover = 已拉取未混完的新曲样本；fade_in_remaining = 旧曲提前耗尽时
    /// 新曲需独自收尾的淡入样本数（正常完成为 0）
    Switched {
        new_rx: Receiver<DecodedFrame>,
        leftover: Vec<f32>,
        fade_in_remaining: usize,
    },
    /// 新流不可用（解码通道断开）或收到停止：放弃混音，旧曲继续播到自然结束，
    /// 回退现有无间隙行为
    Aborted,
}

/// 真交叉淡化混合阶段：旧曲尾部与新曲头部逐样本按余弦曲线叠加。
///
/// 混合发生在 DSP 之前：EQ/滤波等线性环节满足叠加律 `DSP(a+b)=DSP(a)+DSP(b)`，
/// 混合后过一次管线与分别处理声学等价，且限幅器正好保护叠加峰值。
/// 淡变窗口为 `fade_total` 个交错样本；触发时旧曲剩余量 ≈ 窗口长度（引擎侧按位置计算，
/// 200ms 粒度），旧曲早于窗口耗尽则新曲独自完成剩余淡入，晚于窗口则旧曲尾部增益已归零可弃。
#[allow(clippy::too_many_arguments)]
fn run_crossfade_phase(
    old_rx: &Receiver<DecodedFrame>,
    new_rx: Receiver<DecodedFrame>,
    fade_total: usize,
    channels: usize,
    cb: &ConsumerCallbacks<'_>,
    stop: &AtomicBool,
    speed: &Arc<AtomicU32>,
    speed_changer: &mut SpeedChanger,
    timeout: Duration,
) -> CrossfadeOutcome {
    let mut old_stash: Vec<f32> = Vec::new();
    let mut new_stash: Vec<f32> = Vec::new();
    let mut old_eof = false;
    let mut fade_done: usize = 0;
    let mut mixed: Vec<f32> = Vec::with_capacity(8192);

    let result = loop {
        if stop.load(Ordering::SeqCst) {
            break CrossfadeOutcome::Aborted;
        }

        // 旧曲供料：拉至有存量或 EOF
        while old_stash.is_empty() && !old_eof {
            match old_rx.recv_timeout(timeout) {
                Ok(f) => old_stash.extend(f.samples),
                Err(RecvTimeoutError::Timeout) => {
                    if stop.load(Ordering::SeqCst) {
                        break;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => old_eof = true,
            }
        }
        // 新曲供料：断流则放弃混音（旧曲继续播，回退无间隙）
        while new_stash.is_empty() {
            match new_rx.recv_timeout(timeout) {
                Ok(f) => new_stash.extend(f.samples),
                Err(RecvTimeoutError::Timeout) => {
                    if stop.load(Ordering::SeqCst) {
                        return CrossfadeOutcome::Aborted;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return CrossfadeOutcome::Aborted,
            }
        }

        // 旧曲耗尽 → 混音结束（剩余淡入由新曲独自收尾）
        if old_stash.is_empty() {
            break CrossfadeOutcome::Switched {
                new_rx,
                leftover: new_stash,
                fade_in_remaining: fade_total - fade_done,
            };
        }

        let n = old_stash
            .len()
            .min(new_stash.len())
            .min(fade_total - fade_done);
        mixed.clear();
        mixed.extend(old_stash[..n].iter().zip(&new_stash[..n]).enumerate().map(
            |(i, (&o, &nw))| {
                let t = (fade_done + i) as f32 / fade_total as f32;
                let g_in = (1.0 - (t * std::f32::consts::PI).cos()) / 2.0;
                o * (1.0 - g_in) + nw * g_in
            },
        ));
        old_stash.drain(..n);
        new_stash.drain(..n);

        // 坏样本拦截（与主路径一致）：跳过本块但推进淡变位置，保持两流配对
        if mixed.iter().any(|s| !s.is_finite()) {
            (cb.on_bad_frame)();
            fade_done += n;
        } else {
            // DSP → （可选）变速 → 推入；混音块不参与频谱统计（过渡态无展示意义）
            (cb.process_dsp)(&mut mixed);
            let output_buf: &[f32] = {
                let sp = f32::from_bits(speed.load(Ordering::Relaxed));
                if (sp - 1.0).abs() > 0.001 {
                    speed_changer.set_speed(sp);
                    let out = speed_changer.process(&mixed, channels);
                    if out.is_empty() {
                        &mixed
                    } else {
                        out
                    }
                } else {
                    &mixed
                }
            };
            push_with_backoff(output_buf, cb.push_samples, stop);
            // 进度计入旧曲（混合窗口内位置推进到曲尾；切歌后引擎会归零）
            (cb.on_samples_output)(n as u64);
            fade_done += n;
        }

        // 淡变窗口走完：旧曲剩余样本增益已归零，直接丢弃；新曲存量回注主循环
        if fade_done >= fade_total {
            break CrossfadeOutcome::Switched {
                new_rx,
                leftover: new_stash,
                fade_in_remaining: 0,
            };
        }
    };
    result
}

/// 平台无关的解码消费循环。
///
/// 从 `rx` 接收解码帧，依次过 `process_dsp`、可选 crossfade、坏帧检测、`push_samples`。
/// 每 `fft_interval` 帧计算一次频谱，通过 `on_spectrum` 回调。
/// 当 `rx` 断开（曲目播完）时调 `on_end_of_track`：返回新的 rx 继续循环，返回 None 退出。
pub fn run_consumer_loop(
    rx: Receiver<DecodedFrame>,
    config: &ConsumerConfig,
    cb: &ConsumerCallbacks<'_>,
    ctrl: &ConsumerControl,
) {
    let stop = &ctrl.stop;
    let ready_tx = ctrl.ready_tx.clone();
    let speed = ctrl.speed.clone();
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
        120.0, 200.0, 300.0, 450.0, 650.0, 900.0, 1200.0, 1600.0, 2200.0, 3200.0, 4600.0, 6400.0,
        8800.0, 12000.0, 16000.0, 22050.0,
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
    let mut band_peaks = [0.001f32; SPECTRUM_BANDS];
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
    // 交叉淡化阶段多读出的新曲样本（混音按块拉取，尾部残余由此回注主循环）
    let mut carry: Vec<f32> = Vec::new();

    loop {
        if stop.load(Ordering::SeqCst) {
            crate::diag::log(&format!(
                "seq: consumer[{:?}] 循环终止（stop 标志），已处理 {frame_count} 帧",
                std::thread::current().id()
            ));
            break;
        }

        // ── 真交叉淡化：引擎在位置进入淡变窗口时置位触发 ──
        // 直通模式（DoP）不能改比特，不参与；无预加载（单曲/队尾）则忽略触发，
        // 自然回退到无间隙路径。所有失败模式都降级为现有行为，不会产生爆音。
        if config.crossfade_ms > 0
            && fade_total > 0
            && !config.passthrough
            && ctrl.xfade_trigger.swap(false, Ordering::SeqCst)
        {
            if let Some(new_rx) = (cb.take_next_rx)() {
                match run_crossfade_phase(
                    &current_rx,
                    new_rx,
                    fade_total,
                    config.channels as usize,
                    cb,
                    stop,
                    &speed,
                    &mut speed_changer,
                    timeout,
                ) {
                    CrossfadeOutcome::Switched {
                        new_rx,
                        leftover,
                        fade_in_remaining,
                    } => {
                        // 混合完成：新曲接管，淡入已由混音曲线完成（或收尾残余）
                        current_rx = new_rx;
                        carry = leftover;
                        first_frame = false;
                        fade_remaining = fade_in_remaining;
                        (cb.on_crossfaded)();
                        continue;
                    }
                    CrossfadeOutcome::Aborted => {
                        // 新流不可用（断流/停止）：继续播旧曲至自然结束，回退无间隙行为
                        continue;
                    }
                }
            }
        }

        // 取帧：优先消费交叉淡化阶段带回的残余样本，再读通道
        let mut buf: Vec<f32>;
        if !carry.is_empty() {
            buf = std::mem::take(&mut carry);
        } else {
            match current_rx.recv_timeout(timeout) {
                Ok(frame) => buf = frame.samples,
                Err(RecvTimeoutError::Timeout) => {
                    // 暂停/空闲时防止 CPU 空转
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => {
                    crate::diag::log("consumer: 解码通道断开（曲目结束/解码器退出）");
                    // 解码器 channel 断开 → 曲目播完
                    if let Some(new_rx) = (cb.on_end_of_track)() {
                        current_rx = new_rx;
                        // 无缝切歌时重置淡入
                        fade_remaining = fade_total;
                        continue;
                    }
                    break;
                }
            }
        }

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
        let count = buf.len() as u64;

        // 直通模式（DoP）：原样推入，不过任何处理（保护标记比特不被篡改）
        if config.passthrough {
            push_with_backoff(&buf, cb.push_samples, stop);
            (cb.on_samples_output)(count);
            continue;
        }

        // 1) DSP 处理
        (cb.process_dsp)(&mut buf);

        // 2) 实时频谱
        if frame_count.is_multiple_of(config.fft_interval as u64)
            && buf.len() >= fft_size * ch
        {
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
                        band_peaks[b] = if avg > peak { avg * 1.1 } else { peak * 0.93 };
                        bands[b] = (avg / band_peaks[b].max(0.001)).min(1.0);
                    } else {
                        band_peaks[b] *= 0.90;
                    }
                }
                (cb.on_spectrum)(&bands);
            }
        }

        // 3) 坏帧检测（在淡入之前，避免淡入把首帧压到接近零被误判）
        // 只拦截 NaN/Inf：全零是合法静音段（解码器侧已过滤非有限样本），
        // 丢弃会造成可闻空洞且进度不计，故照常输出
        if buf.iter().any(|&s| !s.is_finite()) {
            (cb.on_bad_frame)();
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
            let sp = f32::from_bits(speed.load(Ordering::Relaxed));
            if (sp - 1.0).abs() > 0.001 {
                speed_changer.set_speed(sp);
                let out = speed_changer.process(&buf, ch);
                if out.is_empty() {
                    &buf
                } else {
                    out
                }
            } else {
                &buf
            }
        };

        // 6) 推入 ringbuf（满时退避策略见 push_with_backoff）
        push_with_backoff(output_buf, cb.push_samples, stop);

        // 7) 进度追踪（使用原始解码样本数，追踪源音频位置）
        (cb.on_samples_output)(count);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossbeam_channel::{bounded, unbounded};
    use std::sync::{Arc, Mutex};
    use std::thread;

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
            passthrough: false,
        }
    }

    /// 在后台线程跑 consumer loop，返回 (handle, stop, ready_rx)
    fn spawn_test_consumer<E>(
        rx: Receiver<DecodedFrame>,
        config: ConsumerConfig,
        push_fn: E,
    ) -> (thread::JoinHandle<()>, Arc<AtomicBool>, Receiver<bool>)
    where
        E: Fn(&[f32]) -> usize + Send + 'static,
    {
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let speed = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &push_fn,
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed,
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &config, &cb, &ctrl);
        });
        (handle, stop, ready_rx)
    }

    #[test]
    fn test_ready_handshake() {
        let (tx, rx) = unbounded();
        let (handle, _, ready_rx) = spawn_test_consumer(rx, default_config(), |s| s.len());
        tx.send(make_frame(vec![0.5; 256])).unwrap();
        let ok = ready_rx.recv_timeout(Duration::from_secs(3)).is_ok();
        assert!(ok, "ready signal should be sent");
        drop(tx);
        handle.join().unwrap();
    }

    #[test]
    fn test_all_zero_silence_pushed() {
        // 回归：全零帧是合法静音段，不得被当作坏帧丢弃
        // （旧实现误杀静音段，造成可闻空洞且进度不计）
        let (tx, rx) = unbounded();
        let pushed = Arc::new(Mutex::new(0usize));
        let p = pushed.clone();
        let bad_called = Arc::new(AtomicBool::new(false));
        let b = bad_called.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, _ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| {
                    *p.lock().unwrap() += s.len();
                    s.len()
                },
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {
                    b.store(true, Ordering::SeqCst);
                },
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &default_config(), &cb, &ctrl);
        });

        tx.send(make_frame(vec![0.0; 256])).unwrap();
        // 等静音帧被推入（代替 sleep）
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while *pushed.lock().unwrap() == 0 && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        drop(tx);
        handle.join().unwrap();

        assert_eq!(*pushed.lock().unwrap(), 256, "静音帧应照常推入输出");
        assert!(
            !bad_called.load(Ordering::SeqCst),
            "全零帧不应触发 on_bad_frame"
        );
    }

    #[test]
    fn test_nan_frame_skipped() {
        let (tx, rx) = unbounded();
        let pair = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let pair2 = pair.clone();
        let pushed = Arc::new(Mutex::new(0usize));
        let p = pushed.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, _ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| {
                    *p.lock().unwrap() += s.len();
                    s.len()
                },
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {
                    let (lock, cvar) = &*pair2;
                    *lock.lock().unwrap() = true;
                    cvar.notify_one();
                },
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &default_config(), &cb, &ctrl);
        });

        tx.send(make_frame(vec![f32::NAN; 256])).unwrap();
        let (lock, cvar) = &*pair;
        let guard = lock.lock().unwrap();
        let bad = cvar.wait_timeout(guard, Duration::from_secs(3)).unwrap();
        drop(tx);
        handle.join().unwrap();

        assert!(*bad.0, "on_bad_frame should be called for NaN");
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
            let cb = ConsumerCallbacks {
                push_samples: &|_: &[f32]| 0,
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &cfg, &cb, &ctrl);
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
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| {
                    p.lock().unwrap().extend_from_slice(s);
                    s.len()
                },
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &cfg, &cb, &ctrl);
        });

        let n = (44100.0 * 0.2) as usize * 2; // ~17640 samples
        tx.send(make_frame(vec![1.0; n])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
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
        let (done_tx, done_rx) = bounded::<()>(4);

        let next_rx = Arc::new(Mutex::new(Some(rx2)));
        let nr = next_rx.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| s.len(),
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {
                    let _ = done_tx.send(());
                },
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> {
                    nr.lock().unwrap().take()
                },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &default_config(), &cb, &ctrl);
        });

        tx.send(make_frame(vec![0.5; 256])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        drop(tx);
        // 等第一帧处理完（替代 sleep）
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("frame 1 processed");

        tx2.send(make_frame(vec![0.5; 256])).unwrap();
        // 等第二帧处理完（替代 sleep）
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("frame 2 processed");
        drop(tx2);
        handle.join().unwrap();
    }

    #[test]
    fn test_on_end_of_track_exit_on_none() {
        let (tx, rx) = unbounded();
        let (handle, _, ready_rx) = spawn_test_consumer(rx, default_config(), |s| s.len());
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
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| s.len(),
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {
                    *sc.lock().unwrap() += 1;
                },
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &cfg, &cb, &ctrl);
        });

        for _ in 0..6 {
            tx.send(make_frame(vec![0.5; 4096])).unwrap();
        }
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
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
        let (done_tx, done_rx) = bounded::<()>(4);

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| s.len(),
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|n: u64| {
                    let mut total = ts.lock().unwrap();
                    *total += n;
                    if *total >= 768 {
                        let _ = done_tx.send(());
                    }
                },
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &default_config(), &cb, &ctrl);
        });

        tx.send(make_frame(vec![0.5; 256])).unwrap();
        tx.send(make_frame(vec![0.5; 512])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        // 等待累计样本数达标（替代 sleep）
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("samples should reach 768");
        drop(tx);
        handle.join().unwrap();

        let total = *total_samples.lock().unwrap();
        assert_eq!(
            total, 768,
            "on_samples_output should sum sample counts: got {}",
            total
        );
    }

    #[test]
    fn test_passthrough_skips_dsp_and_pushes_raw() {
        let (tx, rx) = unbounded();
        let pushed = Arc::new(Mutex::new(Vec::new()));
        let p = pushed.clone();
        let dsp_called = Arc::new(Mutex::new(false));
        let dc = dsp_called.clone();
        let (done_tx, done_rx) = bounded::<()>(4);

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let mut cfg = default_config();
        cfg.passthrough = true;
        let handle = thread::spawn(move || {
            let dsp_fn = move |buf: &mut [f32]| {
                *dc.lock().unwrap() = true;
                for sample in buf.iter_mut() {
                    *sample = 0.0;
                }
            };
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| {
                    p.lock().unwrap().extend_from_slice(s);
                    let _ = done_tx.send(());
                    s.len()
                },
                process_dsp: &dsp_fn,
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &cfg, &cb, &ctrl);
        });

        // DoP 风格的“奇怪”数值（含超满刻度负值），必须原样通过
        let dop_like = vec![0.0596f32, -0.0469, 0.0596, -0.0469];
        tx.send(make_frame(dop_like.clone())).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("frame pushed");
        drop(tx);
        handle.join().unwrap();

        assert!(!*dsp_called.lock().unwrap(), "passthrough 不应调用 DSP");
        assert_eq!(
            *pushed.lock().unwrap(),
            dop_like,
            "passthrough 应逐比特原样推送"
        );
    }

    #[test]
    fn test_dsp_processes_samples_in_place() {
        let (tx, rx) = unbounded();
        let processed = Arc::new(Mutex::new(Vec::new()));
        let p = processed.clone();
        let (done_tx, done_rx) = bounded::<()>(4);

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let handle = thread::spawn(move || {
            let dsp_fn = |buf: &mut [f32]| {
                for sample in buf.iter_mut() {
                    *sample *= 2.0;
                }
                p.lock().unwrap().extend_from_slice(buf);
                let _ = done_tx.send(());
            };
            let cb = ConsumerCallbacks {
                push_samples: &|s: &[f32]| s.len(),
                process_dsp: &dsp_fn,
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| -> Option<Receiver<DecodedFrame>> { None },
                take_next_rx: &|| None,
                on_crossfaded: &|| {},
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(false)),
            };
            run_consumer_loop(rx, &default_config(), &cb, &ctrl);
        });

        tx.send(make_frame(vec![1.0; 128])).unwrap();
        let _ = ready_rx.recv_timeout(Duration::from_secs(3));
        // 等待 DSP 处理完成（替代 sleep）
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("dsp should process");
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

    // ── 真交叉淡化 ──

    #[test]
    fn test_crossfade_mixes_two_streams() {
        // 旧曲恒定 1.0、新曲恒定 0.5：触发后混合窗口内输出应为余弦加权和，
        // 窗口末尾 ≈ 新曲幅值，窗口后新曲直接播放，且 on_crossfaded 被调用。
        let (old_tx, old_rx) = unbounded();
        let (new_tx, new_rx) = unbounded();
        let pushed = Arc::new(Mutex::new(Vec::new()));
        let p = pushed.clone();
        let crossfaded = Arc::new(AtomicBool::new(false));
        let cf = crossfaded.clone();
        let next_slot: Arc<Mutex<Option<Receiver<DecodedFrame>>>> =
            Arc::new(Mutex::new(Some(new_rx)));
        let ns = next_slot.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, ready_rx) = bounded(1);
        let trigger = Arc::new(AtomicBool::new(false));
        let trig = trigger.clone();

        let mut cfg = default_config();
        cfg.crossfade_ms = 10; // fade_total = 44100*10/1000*2 = 882 交错样本
        let fade_total = (44100 * 10 / 1000 * 2) as usize;

        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &|smp: &[f32]| {
                    p.lock().unwrap().extend_from_slice(smp);
                    smp.len()
                },
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| None,
                take_next_rx: &|| ns.lock().unwrap().take(),
                on_crossfaded: &|| {
                    cf.store(true, Ordering::SeqCst);
                },
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: trig,
            };
            run_consumer_loop(old_rx, &cfg, &cb, &ctrl);
        });

        // 首帧被首帧淡入消耗（882 样本恰好一个淡入窗口）
        old_tx.send(make_frame(vec![1.0; fade_total])).unwrap();
        assert!(ready_rx.recv_timeout(Duration::from_secs(3)).unwrap_or(false));
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while pushed.lock().unwrap().len() < fade_total
            && std::time::Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(pushed.lock().unwrap().len(), fade_total, "首帧应完整输出");

        // 置位触发，等消费者进入混合阶段（在旧曲等待窗口阻塞）
        trigger.store(true, Ordering::SeqCst);
        thread::sleep(Duration::from_millis(300));

        // 新曲开头先行供料，再发旧曲尾部并断开旧通道 → 混合消耗旧尾部 + 新头部
        new_tx.send(make_frame(vec![0.5; fade_total * 3])).unwrap();
        old_tx.send(make_frame(vec![1.0; fade_total])).unwrap();
        drop(old_tx);

        // 等混合完成 + 部分新曲直接播放段（替代 sleep 的轮询）
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while pushed.lock().unwrap().len() < fade_total * 2 + 100
            && std::time::Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(5));
        }
        stop.store(true, Ordering::SeqCst);
        drop(new_tx);
        handle.join().unwrap();

        assert!(crossfaded.load(Ordering::SeqCst), "on_crossfaded 应被调用");
        let buf = pushed.lock().unwrap();
        // 混合窗口 = pushed[fade_total .. fade_total*2] = 旧*(1-g) + 新*g（余弦）
        let mid = fade_total / 2;
        assert!(
            (buf[fade_total] - 1.0).abs() < 0.02,
            "混合起点应≈旧曲: {}",
            buf[fade_total]
        );
        assert!(
            (buf[fade_total + mid] - 0.75).abs() < 0.03,
            "混合中点应≈0.75: {}",
            buf[fade_total + mid]
        );
        assert!(
            (buf[fade_total * 2 - 1] - 0.5).abs() < 0.02,
            "混合终点应≈新曲: {}",
            buf[fade_total * 2 - 1]
        );
        // 窗口后新曲直接播放，不再叠加增益变化（首样本后若干样本均已稳定）
        assert!(
            (buf[fade_total * 2 + 50] - 0.5).abs() < 1e-3,
            "窗口后应为新曲幅值: {}",
            buf[fade_total * 2 + 50]
        );
    }

    #[test]
    fn test_crossfade_trigger_without_preload_falls_back() {
        // 触发置位但无预加载（单曲/队尾）：忽略触发，旧曲完整播完后经 EOF 退出，
        // 行为与无交叉淡化一致（回退保证）
        let (tx, rx) = unbounded();
        let pushed = Arc::new(Mutex::new(0usize));
        let p = pushed.clone();

        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let (ready_tx, _ready_rx) = bounded(1);
        let mut cfg = default_config();
        cfg.crossfade_ms = 10;

        let handle = thread::spawn(move || {
            let cb = ConsumerCallbacks {
                push_samples: &|smp: &[f32]| {
                    *p.lock().unwrap() += smp.len();
                    smp.len()
                },
                process_dsp: &|_: &mut [f32]| {},
                on_spectrum: &|_: &[f32; SPECTRUM_BANDS]| {},
                on_bad_frame: &|| {},
                on_samples_output: &|_: u64| {},
                on_end_of_track: &|| None,
                take_next_rx: &|| None,
                on_crossfaded: &|| panic!("无预加载时不应发生交叉淡化"),
            };
            let ctrl = ConsumerControl {
                stop: s,
                ready_tx,
                speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
                xfade_trigger: Arc::new(AtomicBool::new(true)),
            };
            run_consumer_loop(rx, &cfg, &cb, &ctrl);
        });

        tx.send(make_frame(vec![0.5; 100])).unwrap();
        drop(tx);
        handle.join().unwrap();
        assert_eq!(*pushed.lock().unwrap(), 100, "旧曲应完整输出后退出");
    }
}
