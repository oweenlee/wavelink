//! 引擎线程主循环 + 消费者线程

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{select, unbounded, Receiver, Sender};
use parking_lot::Mutex;
use ringbuf::traits::Producer;
use tracing::{debug, error, info, warn};

use super::command::{EngineCommand, EngineEvent, Levels};
use super::state::EngineState;
use super::thread_priority::elevate_audio_thread;
use crate::decoder::DecodedFrame;
use crate::dsp::DspPipeline;
use crate::error::EngineError;
use crate::output::{AudioOutputInner, PcmProducer};
use crate::EngineConfig;

/// 用 Symphonia 探测音频时长（微秒）
pub(crate) fn probe_duration_symphonia(path: &std::path::Path) -> Option<u64> {
    crate::decoder::probe_duration_secs(path).map(|secs| (secs * 1_000_000.0) as u64)
}

/// 计算切歌淡入所需的样本数
#[allow(dead_code)]
pub(crate) fn crossfade_sample_count(sample_rate: u32, channels: u32, crossfade_ms: u32) -> usize {
    if crossfade_ms == 0 {
        return 0;
    }
    (sample_rate as usize * channels as usize) * crossfade_ms as usize / 1000
}

/// 引擎线程主循环
pub(crate) fn run_engine(
    cmd_rx: Receiver<EngineCommand>,
    external_tx: Sender<EngineEvent>,
    position: Arc<AtomicU64>,
    duration_us: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    config: EngineConfig,
    config_shared: Arc<RwLock<EngineConfig>>,
    levels: Arc<Mutex<Levels>>,
    output_inner_shared: Arc<RwLock<Option<Arc<AudioOutputInner>>>>,
    output_sample_rate_shared: Arc<std::sync::atomic::AtomicU32>,
    output_mode_shared: Arc<std::sync::atomic::AtomicU8>,
    capture_inner_shared: Arc<std::sync::RwLock<Option<Arc<crate::capture::CaptureInner>>>>,
    dsp_latency_shared: Arc<AtomicU64>,
) {
    let mut state = EngineState::new(
        config,
        position,
        duration_us,
        playing,
        external_tx.clone(),
        levels,
    );
    state.output_inner_shared = Some(output_inner_shared);
    state.output_sample_rate_shared = Some(output_sample_rate_shared);
    state.output_mode_shared = Some(output_mode_shared);
    state.capture_inner_shared = Some(capture_inner_shared);
    state.dsp_latency_shared = Some(dsp_latency_shared);
    info!("引擎线程启动");

    // 创建内部事件 channel：消费者发 "曲目结束" 走这
    let (internal_event_tx, internal_event_rx) = unbounded::<EngineEvent>();
    state.internal_event_tx = internal_event_tx;

    // 备份一份 tx 用于 catch_unwind 后的 panic 通知
    let panic_tx = external_tx.clone();

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut tick = crossbeam_channel::after(Duration::from_millis(200));

        loop {
            select! {
                recv(cmd_rx) -> msg => {
                    match msg {
                        Ok(EngineCommand::Play(p, ack)) => {
                            state.play_file(&p);
                            if let Some(tx) = ack {
                                let _ = tx.send(Ok(()));
                            }
                        }
                        Ok(EngineCommand::PlayStream { format_hint, content_length, ack, stream_handle_out }) => {
                            state.play_stream(format_hint, content_length, ack, stream_handle_out);
                        }
                        Ok(EngineCommand::PlayQueue(paths)) => state.set_queue(paths),
                        Ok(EngineCommand::PlayQueueAt(paths, start)) => state.set_queue_at(paths, start),
                        Ok(EngineCommand::NextTrack) => state.next_track(),
                        Ok(EngineCommand::PrevTrack) => state.prev_track(),
                        Ok(EngineCommand::Pause) => state.pause(),
                        Ok(EngineCommand::Resume) => state.resume(),
                        Ok(EngineCommand::Stop) => state.stop_full(),
                        Ok(EngineCommand::Seek(pos, ack)) => {
                            state.seek(pos);
                            if let Some(tx) = ack {
                                let _ = tx.send(Ok(()));
                            }
                        }
                        Ok(EngineCommand::LoadIr(p)) => state.load_ir(&p),
                        Ok(EngineCommand::ClearIr) => state.clear_ir(),
                        Ok(EngineCommand::SetPeqBand { index, band }) => state.set_peq_band(index, band),
                        Ok(EngineCommand::SetAutoEq(name)) => state.apply_auto_eq(name),
                        Ok(EngineCommand::SetDsdMode(mode)) => state.config.dsd_mode = mode,
                        Ok(EngineCommand::SetStereoWidener { enabled, width }) => state.set_stereo_widener(enabled, width),
                        Ok(EngineCommand::SetCrossfeed(enabled)) => state.set_crossfeed(enabled),
                        Ok(EngineCommand::SetVolume(vol)) => state.set_volume(vol),
                        Ok(EngineCommand::SetReplaygainGain(gain)) => state.set_replaygain_db(gain),
                        Ok(EngineCommand::SetReplaygainPeak(peak)) => state.set_replaygain_peak(peak),
                        Ok(EngineCommand::SetConfig(cfg)) => {
                            let device = state.config.output_device.take();
                            state.config = cfg.clone();
                            state.config.output_device = device;
                            if let Ok(mut shared) = config_shared.write() {
                                *shared = state.config.clone();
                            }
                            info!("引擎配置更新: {}/{}ch/{}ms", state.config.sample_rate, state.config.channels, state.config.buffer_ms);
                        },
                        Ok(EngineCommand::SetBufferMs(ms)) => {
                            if let Some(ref mut output) = state.output {
                                output.set_buffer_ms(ms);
                            }
                            state.config.buffer_ms = ms;
                        },
                        Ok(EngineCommand::SetOutputSampleRate(rate)) => {
                            state.config.sample_rate = rate;
                            // 流重建可能失败（设备不支持目标速率）：此时实际速率不变，
                            // 遥测必须如实报告，否则指示器会误判「速率匹配」
                            let prev = state.output_sample_rate;
                            let actual = match state.output.as_mut() {
                                Some(output) => {
                                    output.set_sample_rate(rate).unwrap_or(prev)
                                }
                                None => rate,
                            };
                            state.output_sample_rate = actual;
                            state.sync_output_sample_rate();
                            state.sync_output_mode(); // 重建后模式可能降级（Exclusive→Shared）
                            if let Ok(mut shared) = config_shared.write() {
                                shared.sample_rate = actual;
                            }
                            if actual == rate {
                                info!("输出采样率设置: {rate}Hz（下次播放生效）");
                            } else {
                                warn!(
                                    "输出采样率设置: 请求 {rate}Hz 重建失败，保持 {actual}Hz"
                                );
                            }
                        },
                        Ok(EngineCommand::SetSpeed(speed)) => state.set_speed(speed),
                        Ok(EngineCommand::SetNoiseShaping(enabled)) => state.set_noise_shaping(enabled),
                        Ok(EngineCommand::SetLimiterEnabled(enabled)) => state.set_limiter_enabled(enabled),
                        Ok(EngineCommand::SetDitherEnabled(enabled)) => state.set_dither_enabled(enabled),
                        Ok(EngineCommand::SetPlayMode(mode)) => state.set_play_mode(mode),
                        Ok(EngineCommand::SetOutputDevice(dev, ack)) => {
                            if state.config.output_device.as_deref() != Some(&dev) {
                                info!("输出设备切换: {dev}（下次播放生效）");
                                state.config.output_device = Some(dev);
                            }
                            if let Some(tx) = ack {
                                let _ = tx.send(Ok(()));
                            }
                        }
                        Ok(EngineCommand::RemoveFromQueue(idx)) => state.remove_from_queue(idx),
                        Ok(EngineCommand::StartCapture { sample_rate, channels }) => {
                            if let Err(e) = crate::capture::start_global_capture(sample_rate, channels) {
                                state.emit(EngineEvent::Error(format!("捕获启动失败: {e}")));
                            } else {
                                // 同步 CaptureInner 到引擎实例（替代全局 CAPTURE_INNER）
                                if let Some(ref shared) = state.capture_inner_shared {
                                    if let Ok(mut guard) = shared.write() {
                                        *guard = crate::capture::capture_inner();
                                    }
                                }
                            }
                        }
                        Ok(EngineCommand::StopCapture) => {
                            crate::capture::stop_global_capture();
                            // 清除引擎实例上的捕获引用
                            if let Some(ref shared) = state.capture_inner_shared {
                                if let Ok(mut guard) = shared.write() {
                                    *guard = None;
                                }
                            }
                        }
                        Ok(EngineCommand::SessionInterruptionBegan) => {
                            state.pause();
                        }
                        Ok(EngineCommand::SessionInterruptionEnded) => {
                            state.resume();
                        }
                        Ok(EngineCommand::QueryUnderrunCount(resp_tx)) => {
                            let count = state.output_inner.as_ref()
                                .map(|o| o.underrun_count.load(Ordering::Relaxed))
                                .unwrap_or(0);
                            let _ = resp_tx.send(count);
                        }
                        Ok(EngineCommand::Quit) | Err(_) => {
                            state.stop_full();
                            break;
                        }
                    }
                }
                recv(internal_event_rx) -> event => {
                    match event {
                        Ok(EngineEvent::TrackChanged(_)) => state.advance_queue(),
                        Ok(other) => { let _ = external_tx.send(other); }
                        Err(_) => break,
                    }
                }
                recv(tick) -> _ => {
                    // 设备断开检测
                    if let Some(ref inner) = state.output_inner {
                        if inner.stream_failed.load(Ordering::Acquire) {
                            crate::diag::log("worker: stream_failed=true，触发恢复");
                            warn!("检测到音频设备断开，尝试恢复...");
                            state.recover_output();
                        }
                    }
                    let pos_samples = state.position.load(Ordering::Acquire);
                    let latency = state.dsp_latency_shared.as_ref()
                        .map(|l| l.load(Ordering::Acquire))
                        .unwrap_or(0);
                    let sr = state.output_sample_rate as f64;
                    let ch = state.config.channels as f64;
                    let pos_secs = pos_samples.saturating_sub(latency) as f64 / (sr * ch);
                    let _ = external_tx.send(EngineEvent::Position(pos_secs));
                    // 定期发送电平事件（与 Position 同频，200ms）
                    let lv = *state.levels.lock();
                    let _ = external_tx.send(EngineEvent::Levels(lv));
                    tick = crossbeam_channel::after(Duration::from_millis(200));
                }
            }
        }
    }));

    if let Err(panic_info) = result {
        let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = panic_info.downcast_ref::<String>() {
            s.clone()
        } else {
            "引擎线程 panic（未知原因）".into()
        };
        error!("引擎线程 crash: {msg}");
        let _ = panic_tx.send(EngineEvent::Error(format!("引擎内部错误: {msg}")));
    }

    info!("引擎线程退出");
}

/// spawn_consumer — crossfade_ms = 0 表示无间隙（不淡入）
pub(crate) fn spawn_consumer(
    rx: Receiver<DecodedFrame>,
    pcm: PcmProducer,
    dsp: Arc<Mutex<DspPipeline>>,
    stop_flag: Arc<AtomicBool>,
    position: Arc<AtomicU64>,
    event_tx: Sender<EngineEvent>,
    ready_tx: Sender<bool>,
    next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>>,
    sample_rate: u32,
    channels: u32,
    crossfade_ms: u32,
    speed: Arc<AtomicU32>,
    levels: Arc<Mutex<Levels>>,
    err_rx: Receiver<EngineError>,
    passthrough: bool,
    playback_gen: Arc<AtomicU64>,
) -> thread::JoinHandle<()> {
    let my_gen = playback_gen.load(Ordering::SeqCst);
    thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // 提升线程优先级（跨平台）
            elevate_audio_thread();

            let config = crate::consumer::ConsumerConfig {
                sample_rate,
                channels,
                fft_interval: 3,
                crossfade_ms,
                recv_timeout_ms: 500,
                passthrough,
            };

            let pcm_mutex = Mutex::new(pcm);
            let callbacks = crate::consumer::ConsumerCallbacks {
                push_samples: &|s| pcm_mutex.lock().push_slice(s),
                process_dsp: &|buf| {
                    dsp.lock().process(buf);
                    // 计算 RMS 和峰值
                    let mut sum_sq = 0.0f32;
                    let mut peak_val = 0.0f32;
                    for &s in buf.iter() {
                        let abs = s.abs();
                        sum_sq += s * s;
                        if abs > peak_val {
                            peak_val = abs;
                        }
                    }
                    let n = buf.len() as f32;
                    let rms = (sum_sq / n).sqrt();
                    let mut lv = levels.lock();
                    lv.rms = rms;
                    lv.peak = lv.peak.max(peak_val) * 0.95;
                    lv.clip = peak_val >= 1.0;
                },
                on_spectrum: &|bands| {
                    let _ = event_tx.send(EngineEvent::Spectrum(bands.to_vec()));
                },
                on_bad_frame: &|| {
                    let _ = event_tx.send(EngineEvent::Error(
                        "解码器输出坏帧（全零/NaN），已跳过".into(),
                    ));
                },
                on_samples_output: &|n| {
                    position.fetch_add(n, Ordering::Release);
                },
                on_end_of_track: &|| {
                    // 检查解码错误（后台解码线程失败时发送）
                    if let Ok(e) = err_rx.try_recv() {
                        let _ = event_tx.send(EngineEvent::Error(e.to_string()));
                    }
                    let mut guard = next_rx.lock();
                    let preloaded = guard.take();
                    if playback_gen.load(Ordering::SeqCst) == my_gen {
                        let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
                    } else {
                        debug!(
                            "消费者线程 gen={my_gen} 已过期（当前 gen={}），跳过 TrackChanged",
                            playback_gen.load(Ordering::Relaxed)
                        );
                    }
                    preloaded
                },
            };
            let control = crate::consumer::ConsumerControl {
                stop: stop_flag,
                ready_tx,
                speed,
            };
            crate::consumer::run_consumer_loop(rx, &config, &callbacks, &control);
        }));
        if let Err(panic_info) = result {
            let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "消费者线程未知 panic".to_string()
            };
            error!("消费者线程 crash: {msg}");
            if playback_gen.load(Ordering::SeqCst) == my_gen {
                let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
            }
        }
        debug!("消费者线程结束");
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossbeam_channel::bounded;

    #[test]
    fn test_probe_duration_nonexistent_file() {
        let dur = probe_duration_symphonia(std::path::Path::new("/tmp/_nonexistent_dur_test.wav"));
        assert!(dur.is_none(), "不存在的文件应返回 None");
    }

    #[test]
    fn test_crossfade_sample_count() {
        let n = crossfade_sample_count(44100, 2, 50);
        assert_eq!(n, 4410, "50ms 立体声应 = 4410 samples");
        assert_eq!(
            crossfade_sample_count(48000, 2, 50),
            4800,
            "48kHz 50ms 立体声"
        );
        assert_eq!(
            crossfade_sample_count(44100, 1, 50),
            2205,
            "44.1kHz 50ms 单声道"
        );
    }

    #[test]
    fn test_crossfade_curve_starts_at_zero() {
        let gain = (1.0 - (0.0f32 * std::f32::consts::PI).cos()) / 2.0;
        assert!((gain - 0.0).abs() < 1e-6, "i=0 时 gain 应为 0, 实际 {gain}");
    }

    #[test]
    fn test_crossfade_curve_midpoint() {
        let gain = (1.0 - (0.5f32 * std::f32::consts::PI).cos()) / 2.0;
        assert!(
            (gain - 0.5).abs() < 0.01,
            "i=total/2 时 gain 应 ≈0.5, 实际 {gain}"
        );
    }

    #[test]
    fn test_crossfade_curve_ends_at_one() {
        let gain = (1.0 - (1.0f32 * std::f32::consts::PI).cos()) / 2.0;
        assert!(
            (gain - 1.0).abs() < 1e-6,
            "i=total 时 gain 应为 1, 实际 {gain}"
        );
    }

    #[test]
    fn test_crossfade_fade_remaining_reset_on_switch() {
        use ringbuf::traits::Split;

        let (tx1, rx1) = unbounded::<DecodedFrame>();
        let dsp = Arc::new(Mutex::new(DspPipeline::new(44100, 2, &[], false, 1.0, 24)));
        let stop = Arc::new(AtomicBool::new(false));
        let pos = Arc::new(AtomicU64::new(0));
        let (ev_tx, _ev_rx) = unbounded();
        let (ready_tx, ready_rx) = unbounded();
        let next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>> = Arc::new(Mutex::new(None));

        let rb = ringbuf::HeapRb::<f32>::new(65536);
        let (prod, _cons) = rb.split();

        let consumer = spawn_consumer(
            rx1,
            prod,
            dsp,
            stop.clone(),
            pos,
            ev_tx,
            ready_tx,
            next_rx.clone(),
            44100,
            2,
            0,
            Arc::new(AtomicU32::new(1.0f32.to_bits())),
            Arc::new(Mutex::new(Levels::default())),
            bounded(1).1,
            false,
            Arc::new(AtomicU64::new(1)),
        );

        let frame = DecodedFrame {
            samples: vec![0.5f32; 1024],
            pts_secs: 0.0,
            sample_rate: 44100,
            channels: 2,
        };
        tx1.send(frame).ok();
        assert!(
            ready_rx
                .recv_timeout(Duration::from_secs(1))
                .unwrap_or(false),
            "消费者应就绪"
        );

        drop(tx1);
        thread::sleep(Duration::from_millis(50));

        assert!(!stop.load(Ordering::Acquire), "消费者不应被 stop 停止");
        stop.store(true, Ordering::SeqCst);
        let _ = consumer.join();
    }

    #[test]
    fn test_engine_handle_start_stop_cycle() {
        use super::super::handle::EngineHandle;
        let (handle, _rx) = EngineHandle::start();
        assert!(!handle.is_playing(), "初始应未播放");
        assert_eq!(handle.position_secs(), 0.0);
        assert_eq!(handle.duration_secs(), 0.0);
        handle.stop();
        drop(handle);
    }

    #[test]
    fn test_engine_config_default() {
        let cfg = EngineConfig::default();
        assert_eq!(cfg.sample_rate, 44100);
        assert_eq!(cfg.channels, 2);
        assert_eq!(cfg.buffer_ms, 280);
    }

    #[test]
    fn test_engine_config_custom() {
        let cfg = EngineConfig {
            sample_rate: 96000,
            channels: 2,
            buffer_ms: 50,
            crossfade_ms: 0,
            output_device: None,
            ..Default::default()
        };
        assert_eq!(cfg.sample_rate, 96000);
        assert_eq!(cfg.buffer_ms, 50);
    }

    #[test]
    fn test_start_with_config_position() {
        use super::super::handle::EngineHandle;
        let cfg = EngineConfig {
            sample_rate: 96000,
            channels: 2,
            buffer_ms: 80,
            crossfade_ms: 0,
            output_device: None,
            ..Default::default()
        };
        let (handle, _rx) = EngineHandle::start_with_config(cfg);
        assert_eq!(handle.position_secs(), 0.0);
        handle.position.store(96000 * 2 * 5, Ordering::SeqCst);
        let pos = handle.position_secs();
        assert!(
            (pos - 5.0).abs() < 0.001,
            "96000Hz 下 5s 应≈5.0, 实际: {pos}"
        );
        drop(handle);
    }

    #[test]
    fn test_start_with_config_44100_position() {
        use super::super::handle::EngineHandle;
        let cfg = EngineConfig {
            sample_rate: 44100,
            channels: 1,
            buffer_ms: 80,
            crossfade_ms: 0,
            output_device: None,
            ..Default::default()
        };
        let (handle, _rx) = EngineHandle::start_with_config(cfg);
        handle.position.store(44100 * 10, Ordering::SeqCst);
        let pos = handle.position_secs();
        assert!(
            (pos - 10.0).abs() < 0.001,
            "44100Hz 单声道 10s 应≈10.0, 实际: {pos}"
        );
        drop(handle);
    }
}
