//! EngineState — 引擎内部运行状态（只存在于引擎线程）

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{unbounded, Receiver, Sender};
use parking_lot::Mutex;
use tracing::{debug, error, info, warn};

use super::command::{EngineEvent, Levels, PlayMode};
use super::queue::{resolve_entries, QueueEntry};
use super::worker::spawn_consumer;
use crate::decoder::{Decoder, DecodedFrame};
use crate::dsp::{DspPipeline, PeqBand};
use crate::output::{AudioOutput, AudioOutputInner};
use crate::stream::StreamHandle;
use crate::EngineConfig;

/// 引擎内部运行状态（只存在于引擎线程）
pub struct EngineState {
    pub(crate) config: EngineConfig,
    pub(crate) output: Option<Box<dyn AudioOutput>>,
    pub(crate) output_inner: Option<Arc<AudioOutputInner>>,
    /// cpal 实际运行的采样率（可能与 config.sample_rate 不同，如果 fallback 了）
    pub(crate) output_sample_rate: u32,
    pub(crate) decoder: Option<Decoder>,
    pub(crate) consumer_thread: Option<thread::JoinHandle<()>>,
    pub(crate) dsp: Option<Arc<Mutex<DspPipeline>>>,
    pub(crate) consumer_stop: Option<Arc<AtomicBool>>,
    pub(crate) current_volume: f32,
    pub(crate) pending_ir: Option<String>,
    pub(crate) pending_replaygain_db: Option<f32>,
    /// ReplayGain 真峰值（限制增益不过载）
    pub(crate) pending_replaygain_peak: Option<f32>,
    pub(crate) current_entry: Option<QueueEntry>,
    pub(crate) position: Arc<AtomicU64>,
    pub(crate) queue: Vec<QueueEntry>,
    pub(crate) external_tx: Sender<EngineEvent>,
    pub(crate) internal_event_tx: Sender<EngineEvent>,
    pub(crate) peq_bands: Vec<PeqBand>,
    pub(crate) duration_us: Arc<AtomicU64>,
    pub(crate) playing: Arc<AtomicBool>,
    /// 预加载的下一首（无缝播放）
    pub(crate) next_entry: Option<QueueEntry>,
    pub(crate) next_decoder: Option<Decoder>,
    pub(crate) next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>>,
    /// 播放模式
    pub(crate) play_mode: PlayMode,
    /// 原始播放队列（RepeatAll 时用于重新填充）
    pub(crate) original_queue: Vec<QueueEntry>,
    /// 播放历史栈（用于"上一首"）
    pub(crate) history: Vec<QueueEntry>,
    /// 变速共享状态（无锁，f32::to_bits 存储）
    pub(crate) speed: Arc<AtomicU32>,
    /// 实时电平
    pub(crate) levels: Arc<Mutex<Levels>>,
    /// 共享输出内部状态（替代全局 static，供 EngineHandle/FFI 读取）
    pub(crate) output_inner_shared: Option<Arc<RwLock<Option<Arc<AudioOutputInner>>>>>,
    /// 流式播放的写入句柄（网络流媒体用，FFI 层通过此句柄写入数据）
    pub(crate) stream_handle: Option<StreamHandle>,
    /// 共享的实际输出采样率（与 EngineHandle 同步）
    pub(crate) output_sample_rate_shared: Option<Arc<AtomicU32>>,
    /// 当前播放是否已获取排他模式（跟踪实际状态，避免 config 被修改后不一致）
    pub(crate) exclusive_mode_acquired: bool,
    /// 当前输出位深（dither 用，默认 24）
    pub(crate) output_bit_depth: u32,
    /// 共享捕获缓冲（与 EngineHandle 同步，替代全局 CAPTURE_INNER）
    pub(crate) capture_inner_shared: Option<Arc<RwLock<Option<Arc<crate::capture::CaptureInner>>>>>,
}

impl EngineState {
    pub(crate) fn new(config: EngineConfig, position: Arc<AtomicU64>, duration_us: Arc<AtomicU64>, playing: Arc<AtomicBool>, external_tx: Sender<EngineEvent>, levels: Arc<Mutex<Levels>>) -> Self {
        let (internal_event_tx, _) = unbounded();
        EngineState {
            output_sample_rate: config.sample_rate,
            config,
            output: None,
            output_inner: None,
            decoder: None,
            consumer_thread: None,
            dsp: None,
            consumer_stop: None,
            current_volume: 1.0,
            pending_ir: None,
            pending_replaygain_db: None,
            pending_replaygain_peak: None,
            current_entry: None,
            position,
            queue: Vec::new(),
            external_tx,
            internal_event_tx,
            peq_bands: crate::dsp::default_peq_bands(),
            duration_us,
            playing,
            next_entry: None,
            next_decoder: None,
            next_rx: Arc::new(Mutex::new(None)),
            play_mode: PlayMode::Normal,
            original_queue: Vec::new(),
            history: Vec::new(),
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            levels,
            output_inner_shared: None,
            stream_handle: None,
            output_sample_rate_shared: None,
            exclusive_mode_acquired: false,
            output_bit_depth: 24,
            capture_inner_shared: None,
        }
    }

    /// 同步 output_inner 到共享引用（供 EngineHandle/FFI 访问）
    pub(crate) fn sync_output_inner(&self) {
        if let Some(ref shared) = self.output_inner_shared {
            if let Ok(mut guard) = shared.write() {
                *guard = self.output_inner.clone();
            }
        }
    }

    /// 同步 output_sample_rate 到共享原子（供 EngineHandle 读取）
    pub(crate) fn sync_output_sample_rate(&self) {
        if let Some(ref shared) = self.output_sample_rate_shared {
            shared.store(self.output_sample_rate, Ordering::Release);
        }
    }

    pub(crate) fn play_entry(&mut self, entry: &QueueEntry) {
        info!("播放: {} (file={}, start={}s, end={}s)",
            entry.display, entry.audio_file, entry.start_secs, entry.end_secs);
        // 记录历史（用于"上一首"）
        if let Some(ref cur) = self.current_entry {
            if cur.display != entry.display {
                self.history.push(cur.clone());
                if self.history.len() > 100 {
                    self.history.remove(0);
                }
            }
        }
        self.stop_playback();
        self.position.store(0, Ordering::SeqCst);
        self.current_entry = Some(entry.clone());
        let path_buf = Path::new(&entry.audio_file).to_path_buf();

        if !path_buf.exists() {
            error!("文件不存在: {}", entry.audio_file);
            self.emit(EngineEvent::Error(format!("文件不存在: {}", entry.audio_file)));
            self.advance_queue();
            return;
        }

        let mut sr = self.config.sample_rate;
        let ch = self.config.channels;
        let mut source_bit_depth: u16 = 0;

        // bit-perfect 模式：探测源文件采样率和位深，强制精确匹配
        if self.config.bit_perfect {
            if let Some(file_sr) = crate::decoder::probe_sample_rate(&path_buf) {
                sr = file_sr;
            }
            source_bit_depth = crate::decoder::probe_bit_depth(&path_buf).unwrap_or(24);
            info!("bit-perfect 模式: 采样率 {}Hz, 位深 {}bit", sr, source_bit_depth);
        }

        // 计算时长（CUE 分轨使用虚轨时长）
        let dur = if entry.end_secs > 0.0 {
            ((entry.end_secs - entry.start_secs) * 1_000_000.0) as u64
        } else {
            let full = super::worker::probe_duration_symphonia(&path_buf).unwrap_or(0);
            full.saturating_sub((entry.start_secs * 1_000_000.0) as u64)
        };
        self.duration_us.store(dur, Ordering::Release);

        // 复用已有或打开新 output
        let (pcm, actual_sr, actual_ch) =
            match super::output_setup::setup_output_for_entry(
                self, &path_buf, ch, sr, source_bit_depth,
            ) {
                Ok(setup) => (setup.pcm, setup.actual_sr, setup.actual_ch),
                Err(()) => {
                    self.advance_queue();
                    return;
                }
            };

        let (rx, decoder) = match Decoder::start(
            &path_buf, actual_sr, actual_ch, self.position.clone(),
            entry.seek_pos(), entry.end_secs_opt(),
        ) {
            Ok(v) => v,
            Err(e) => {
                error!("启动解码失败: {e}");
                self.emit(EngineEvent::Error(format!("解码失败: {e}")));
                self.advance_queue();
                return;
            }
        };
        let dsp = Arc::new(Mutex::new(DspPipeline::new(
            actual_sr, actual_ch as usize, &self.peq_bands,
            true, self.current_volume, self.output_bit_depth,
        )));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let position_clone = self.position.clone();
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), actual_sr, actual_ch, self.config.crossfade_ms, self.speed.clone(), self.levels.clone());
        let output = match self.output.as_ref() {
            Some(o) => o,
            None => { error!("播放时输出设备未初始化"); self.stop_playback(); self.advance_queue(); return; }
        };
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                info!("播放: {}", entry.display);
                self.playing.store(true, Ordering::Release);
                let _ = self.external_tx.send(EngineEvent::TrackChanged(entry.display.clone()));
                let dur = self.duration_us.load(Ordering::Acquire);
                if dur > 0 {
                    let _ = self.external_tx.send(EngineEvent::DurationSecs(dur as f64 / 1_000_000.0));
                }
                self.emit_queue();
            }
            _ => {
                error!("解码失败（无有效音频帧）: {}", entry.display);
                self.emit(EngineEvent::Error(format!("解码失败: {} - 无有效音频数据", entry.display)));
                self.stop_playback();
                self.advance_queue();
                return;
            }
        }

        self.decoder = Some(decoder);
        self.consumer_thread = Some(consumer);
        self.dsp = Some(dsp);
        self.consumer_stop = Some(stop_flag);
        self.apply_pending_replaygain();

        if let Some(ir_path) = self.pending_ir.clone() {
            if let Some(dsp) = &self.dsp {
                if let Err(e) = dsp.lock().load_conv_ir(&ir_path) {
                    error!("加载 IR 失败(play_file): {e}");
                    self.pending_ir = None;
                }
            }
        }

        self.preload_next();
    }

    /// 从流式数据源播放（网络流媒体用）。
    pub(crate) fn play_stream(
        &mut self,
        format_hint: Option<String>,
        content_length: Option<u64>,
        stream_handle_out: Option<std::sync::Arc<crossbeam_channel::Sender<StreamHandle>>>,
    ) {
        self.stop_playback();
        self.stream_handle = None;
        self.current_entry = None;

        let sr = self.config.sample_rate;
        let ch = self.config.channels;

        // 复用或创建输出
        let (pcm, actual_sr, actual_ch) = if let Some(ref mut output) = self.output {
            let out_sr = self.output_sample_rate;
            let out_ch = self.config.channels;
            (output.swap_consumer(self.config.buffer_ms, out_sr, out_ch), out_sr, out_ch)
        } else {
            if self.config.exclusive_mode {
                crate::exclusive::acquire_exclusive_mode();
                self.exclusive_mode_acquired = true;
            }
            match crate::output::open(ch, sr, self.config.buffer_ms, self.config.output_device.as_deref(), 0) {
                Ok((output, prod, inner, actual_rate)) => {
                    self.output_inner = Some(inner);
                    self.output = Some(output);
                    self.output_sample_rate = actual_rate;
                    self.sync_output_sample_rate();
                    self.sync_output_inner();
                    (prod, actual_rate, ch)
                }
                Err(e) => {
                    error!("流式: 打开音频输出失败: {e}");
                    self.emit(EngineEvent::Error(format!("打开音频输出失败: {e}")));
                    return;
                }
            }
        };

        // 创建流式数据源对
        let (source, handle) = crate::stream::stream_pair(content_length);

        // 启动流式解码
        let (rx, decoder) = match Decoder::start_from_stream(
            source, actual_sr, actual_ch, self.position.clone(), format_hint,
        ) {
            Ok(v) => v,
            Err(e) => {
                error!("流式: 启动解码失败: {e}");
                self.emit(EngineEvent::Error(format!("流式解码失败: {e}")));
                return;
            }
        };

        let dsp = Arc::new(Mutex::new(DspPipeline::new(
            actual_sr, actual_ch as usize, &self.peq_bands,
            true, self.current_volume, self.output_bit_depth,
        )));
        if self.config.bit_perfect {
            dsp.lock().set_bypass(true);
        }
        let stop_flag = Arc::new(AtomicBool::new(false));
        let position_clone = self.position.clone();
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), actual_sr, actual_ch, self.config.crossfade_ms, self.speed.clone(), self.levels.clone());

        let output = match self.output.as_ref() {
            Some(o) => o,
            None => { error!("流式播放时输出设备未初始化"); self.stop_playback(); return; }
        };
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                info!("流式播放已启动");
                self.playing.store(true, Ordering::Release);
                let _ = self.external_tx.send(EngineEvent::TrackChanged("stream".into()));
                self.emit_queue();
            }
            _ => {
                error!("流式: 解码失败（无有效音频帧）");
                self.emit(EngineEvent::Error("流式解码失败: 无有效音频数据".into()));
                self.stop_playback();
                return;
            }
        }

        self.decoder = Some(decoder);
        self.consumer_thread = Some(consumer);
        self.dsp = Some(dsp);
        self.consumer_stop = Some(stop_flag);
        self.stream_handle = Some(handle.clone());
        self.apply_pending_replaygain();

        // 将 StreamHandle 克隆一份发送给 FFI 层
        if let Some(tx) = stream_handle_out {
            let _ = tx.send(handle);
        }
    }

    pub(crate) fn play_file(&mut self, path: &str) {
        let entries = resolve_entries(vec![path.to_string()]);
        if entries.is_empty() {
            self.emit(EngineEvent::Error(format!("无法解析音轨: {path}")));
            return;
        }
        if entries.len() == 1 {
            self.play_entry(&entries[0]);
        } else {
            let first = entries[0].clone();
            self.queue = entries[1..].to_vec();
            self.original_queue = entries;
            self.play_entry(&first);
        }
    }

    pub(crate) fn seek(&mut self, pos: f64) {
        let entry = match &self.current_entry {
            Some(e) => e.clone(),
            None => { error!("seek 时无当前曲目"); return; }
        };
        let file_pos = entry.start_secs + pos;
        info!("seek_to: track={pos:.2}s, file={file_pos:.2}s");
        let sr = self.output_sample_rate;
        let ch = self.config.channels;
        let target_samples = (pos * sr as f64 * ch as f64) as u64;
        self.stop_playback();
        self.position.store(target_samples, Ordering::SeqCst);
        let path_buf = Path::new(&entry.audio_file).to_path_buf();
        if !path_buf.exists() {
            error!("文件不存在: {}", entry.audio_file);
            return;
        }

        let pcm = match self.output.as_ref() {
            Some(o) => o.swap_consumer(self.config.buffer_ms, sr, ch),
            None => { error!("seek 时输出设备未初始化"); return; }
        };

        let (rx, decoder) = match Decoder::start(
            &path_buf, sr, ch, self.position.clone(),
            Some(file_pos), entry.end_secs_opt(),
        ) {
            Ok(v) => v,
            Err(e) => { error!("seek 启动解码失败: {e}"); return; }
        };
        let dsp = Arc::new(Mutex::new(DspPipeline::new(
            sr, ch as usize, &self.peq_bands,
            true, self.current_volume, self.output_bit_depth,
        )));
        if self.config.bit_perfect {
            dsp.lock().set_bypass(true);
            info!("bit-perfect: DSP 管线已绕过");
        }
        let stop_flag = Arc::new(AtomicBool::new(false));
        let position_clone = self.position.clone();
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), sr, ch, self.config.crossfade_ms, self.speed.clone(), self.levels.clone());
        let output = match self.output.as_ref() {
            Some(o) => o,
            None => { error!("seek 后输出设备未初始化"); return; }
        };
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                info!("seek 到 {pos:.2}s 后恢复播放: {}", entry.display);
            }
            _ => {
                error!("seek 后解码失败: {}", entry.audio_file);
                let _ = self.internal_event_tx.send(EngineEvent::Error(format!("seek 后解码失败: {}", entry.audio_file)));
                return;
            }
        }

        self.decoder = Some(decoder);
        self.consumer_thread = Some(consumer);
        self.dsp = Some(dsp);
        self.consumer_stop = Some(stop_flag);
        self.apply_pending_replaygain();

        let _ = self.external_tx.send(EngineEvent::Position(pos));
    }

    // ── 预加载 / 无缝切歌 ──

    pub(crate) fn preload_next(&mut self) {
        if self.queue.is_empty() { return; }
        let entry = &self.queue[0];
        let path_buf = Path::new(&entry.audio_file).to_path_buf();
        if !path_buf.exists() {
            error!("预加载文件不存在: {}", entry.audio_file);
            return;
        }
        let dummy_pos = Arc::new(AtomicU64::new(0));
        let sr = self.output_sample_rate;
        let ch = self.config.channels;
        let (rx, decoder) = match Decoder::start(
            &path_buf, sr, ch, dummy_pos,
            entry.seek_pos(), entry.end_secs_opt(),
        ) {
            Ok(v) => v,
            Err(e) => { error!("预加载解码失败: {e}"); return; }
        };
        *self.next_rx.lock() = Some(rx);
        self.next_decoder = Some(decoder);
        self.next_entry = Some(entry.clone());
        debug!("已预加载: {}", self.next_entry.as_ref().unwrap().display);
    }

    /// 计算 QueueEntry 的时长（微秒）
    pub(crate) fn compute_duration_us(&self, entry: &QueueEntry) -> u64 {
        if entry.end_secs > 0.0 {
            ((entry.end_secs - entry.start_secs) * 1_000_000.0) as u64
        } else {
            let path_buf = Path::new(&entry.audio_file).to_path_buf();
            let full = super::worker::probe_duration_symphonia(&path_buf).unwrap_or(0);
            full.saturating_sub((entry.start_secs * 1_000_000.0) as u64)
        }
    }

    /// 无缝切歌时更新元数据（时长 + 事件）
    pub(crate) fn seamless_switch(&mut self, next: &QueueEntry) {
        debug!("无缝切换至: {}", next.display);
        self.current_entry = self.next_entry.take();
        self.decoder = self.next_decoder.take();
        self.position.store(0, Ordering::SeqCst);
        let dur = self.compute_duration_us(next);
        self.duration_us.store(dur, Ordering::Release);
        let _ = self.external_tx.send(EngineEvent::TrackChanged(next.display.clone()));
        if dur > 0 {
            let _ = self.external_tx.send(EngineEvent::DurationSecs(dur as f64 / 1_000_000.0));
        }
        self.emit_queue();
        self.preload_next();
    }

    // ── DSP 配置 ──

    pub(crate) fn apply_pending_replaygain(&mut self) {
        if let Some(gain_db) = self.pending_replaygain_db {
            let effective = self.effective_replaygain_db(gain_db);
            if let Some(dsp) = &self.dsp {
                dsp.lock().set_replaygain_db(effective);
            }
        }
    }

    /// 计算有效 ReplayGain 增益：用 peak 标签限制增益不超过 0dBFS
    fn effective_replaygain_db(&self, gain_db: f32) -> f32 {
        match self.pending_replaygain_peak {
            Some(peak) if peak > 0.0 => {
                let max_gain_db = -20.0 * peak.log10();
                if gain_db > max_gain_db {
                    tracing::debug!("ReplayGain 增益受 peak 限制: {gain_db:.1}dB → {max_gain_db:.1}dB (peak={peak})");
                }
                gain_db.min(max_gain_db)
            }
            _ => gain_db,
        }
    }

    pub(crate) fn load_ir(&mut self, path: &str) {
        self.pending_ir = Some(path.to_string());
        if let Some(dsp) = &self.dsp {
            if let Err(e) = dsp.lock().load_conv_ir(path) {
                error!("加载 IR 失败: {e}");
                self.pending_ir = None;
            }
        }
    }

    pub(crate) fn clear_ir(&mut self) {
        self.pending_ir = None;
        if let Some(dsp) = &self.dsp {
            dsp.lock().clear_conv_ir();
        }
    }

    pub(crate) fn set_peq_band(&mut self, index: usize, band: PeqBand) {
        if index < self.peq_bands.len() {
            self.peq_bands[index] = PeqBand { freq: band.freq, gain_db: band.gain_db, q: band.q };
        }
        if let Some(dsp) = &self.dsp {
            dsp.lock().set_peq_band(index, &band, self.output_sample_rate as f32);
        }
    }

    pub(crate) fn set_stereo_widener(&mut self, enabled: bool, width: f32) {
        if let Some(dsp) = &self.dsp {
            dsp.lock().set_stereo_widener(enabled, width);
        }
    }

    pub(crate) fn set_crossfeed(&mut self, enabled: bool) {
        if let Some(dsp) = &self.dsp {
            dsp.lock().set_crossfeed(enabled);
        }
    }

    pub(crate) fn set_volume(&mut self, vol: f32) {
        self.current_volume = vol;
        if let Some(dsp) = &self.dsp {
            dsp.lock().set_volume(vol);
        }
    }

    pub(crate) fn set_replaygain_db(&mut self, gain_db: f32) {
        self.pending_replaygain_db = Some(gain_db);
        let effective = self.effective_replaygain_db(gain_db);
        if let Some(dsp) = &self.dsp {
            dsp.lock().set_replaygain_db(effective);
        }
    }

    pub(crate) fn set_replaygain_peak(&mut self, peak: Option<f32>) {
        self.pending_replaygain_peak = peak;
        // 更新 peak 后重新应用增益限制
        self.apply_pending_replaygain();
    }

    pub(crate) fn set_speed(&mut self, speed: f32) {
        let s = speed.clamp(0.25, 4.0);
        self.speed.store(s.to_bits(), Ordering::Relaxed);
        info!("播放速度: {s:.2}x");
    }

    // ── 播放控制 ──

    pub(crate) fn pause(&mut self) {
        self.playing.store(false, Ordering::Release);
        if let Some(dsp) = &self.dsp {
            dsp.lock().start_fade_out(5);
        }
        if let Some(o) = &self.output { o.pause(); }
    }

    pub(crate) fn resume(&self) {
        if let Some(o) = &self.output { o.resume(); }
        if let Some(dsp) = &self.dsp {
            dsp.lock().start_fade_in(5);
        }
        self.playing.store(true, Ordering::Release);
    }

    pub(crate) fn stop_full(&mut self) {
        if let Some(dsp) = &self.dsp {
            dsp.lock().start_fade_out(3);
        }
        self.stop_playback();
        self.position.store(0, Ordering::SeqCst);
        self.output = None;
        self.output_inner = None;
        self.sync_output_inner();
        // 释放独占模式（使用实际获取时的状态，而非当前 config）
        if self.exclusive_mode_acquired {
            crate::exclusive::release_exclusive_mode();
            self.exclusive_mode_acquired = false;
        }
    }

    pub(crate) fn stop_playback(&mut self) {
        self.playing.store(false, Ordering::Release);
        if let Some(flag) = &self.consumer_stop { flag.store(true, Ordering::SeqCst); }
        if let Some(d) = &self.decoder { d.stop(); }
        if let Some(d) = &self.next_decoder { d.stop(); }
        if let Some(o) = &self.output { o.pause(); }
        // 带超时的 join：消费者线程 recv_timeout 最大 500ms，留 2s 余量
        if let Some(t) = self.consumer_thread.take() {
            let (done_tx, done_rx) = crossbeam_channel::bounded::<()>(1);
            std::thread::spawn(move || { let _ = t.join(); let _ = done_tx.send(()); });
            if done_rx.recv_timeout(Duration::from_secs(2)).is_err() {
                warn!("消费者线程 join 超时（2s），放弃等待");
            }
        }
        self.decoder = None;
        self.next_decoder = None;
        self.next_entry = None;
        self.consumer_stop = None;
        self.dsp = None;
    }

    // ── 事件 ──

    pub(crate) fn emit(&self, event: EngineEvent) {
        if self.external_tx.send(event).is_err() {
            tracing::warn!("事件发送失败：事件接收器已断开");
        }
    }

    pub(crate) fn emit_queue(&self) {
        if let Some(ref entry) = self.current_entry {
            let full: Vec<String> = if self.original_queue.is_empty() {
                vec![entry.display.clone()]
            } else {
                self.original_queue.iter().map(|e| e.display.clone()).collect()
            };
            if self.external_tx.send(EngineEvent::QueueChanged(full, entry.display.clone())).is_err() {
                tracing::warn!("QueueChanged 事件发送失败：事件接收器已断开");
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crossbeam_channel::unbounded;

    pub fn make_state(queue: Vec<String>, mode: PlayMode) -> (EngineState, Receiver<EngineEvent>) {
        let (tx, rx) = unbounded();
        let position = Arc::new(AtomicU64::new(0));
        let duration = Arc::new(AtomicU64::new(0));
        let playing = Arc::new(AtomicBool::new(false));
        let (internal_tx, _) = unbounded();
        let queue_entries: Vec<QueueEntry> = queue.into_iter().map(|s| QueueEntry::for_file(s)).collect();
        let s = EngineState {
            config: EngineConfig::default(),
            output: None,
            output_inner: None,
            output_sample_rate: 44100,
            decoder: None,
            consumer_thread: None,
            dsp: None,
            consumer_stop: None,
            current_volume: 1.0,
            pending_ir: None,
            pending_replaygain_db: None,
            pending_replaygain_peak: None,
            current_entry: Some(QueueEntry::for_file("/tmp/test.wav".into())),
            position,
            queue: queue_entries,
            external_tx: tx.clone(),
            internal_event_tx: internal_tx,
            peq_bands: crate::dsp::default_peq_bands(),
            duration_us: duration,
            playing,
            next_entry: None,
            next_decoder: None,
            next_rx: Arc::new(Mutex::new(None)),
            play_mode: mode,
            original_queue: vec![
                QueueEntry::for_file("/tmp/a.wav".into()),
                QueueEntry::for_file("/tmp/b.wav".into()),
            ],
            history: Vec::new(),
            speed: Arc::new(AtomicU32::new(1.0f32.to_bits())),
            levels: Arc::new(Mutex::new(Levels::default())),
            output_inner_shared: None,
            stream_handle: None,
            output_sample_rate_shared: None,
            exclusive_mode_acquired: false,
            output_bit_depth: 24,
            capture_inner_shared: None,
        };
        (s, rx)
    }

    #[test]
    fn test_pause_resume_toggles_playing() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        assert!(!state.playing.load(Ordering::Acquire), "初始应为未播放");
        state.resume();
        assert!(state.playing.load(Ordering::Acquire), "resume 后应为 true");
        state.pause();
        assert!(!state.playing.load(Ordering::Acquire), "pause 后应为 false");
    }

    #[test]
    fn test_stop_playback_idempotent() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        state.stop_playback();
        assert!(state.decoder.is_none());
        assert!(state.consumer_thread.is_none());
        state.stop_playback();
    }

    #[test]
    fn test_seek_no_current_path_does_nothing() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        state.current_entry = None;
        state.seek(10.0);
    }

    #[test]
    fn test_emit_queue_with_current_entry() {
        let (state, rx) = make_state(
            vec!["/tmp/song1.wav".into()],
            PlayMode::Normal,
        );
        state.emit_queue();
        let ev = rx.recv_timeout(Duration::from_millis(200));
        assert!(ev.is_ok(), "应发出事件");
    }

    #[test]
    fn test_next_track_with_preloaded_switches() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into()],
            PlayMode::Normal,
        );
        state.next_entry = Some(QueueEntry::for_file("/tmp/next1.wav".into()));
        state.current_entry = Some(QueueEntry::for_file("/tmp/current.wav".into()));
        if !state.queue.is_empty() {
            let next = state.queue.remove(0);
            let match_seamless = state.next_entry.as_ref()
                .map(|e| e.display == next.display)
                .unwrap_or(false);
            if match_seamless {
                state.current_entry = state.next_entry.take();
                state.decoder = state.next_decoder.take();
                state.position.store(0, Ordering::SeqCst);
            }
        }
        assert!(state.queue.is_empty(), "队列应已清空");
        assert_eq!(state.current_entry.as_ref().map(|e| e.display.as_str()), Some("/tmp/next1.wav"));
        assert!(state.next_entry.is_none(), "next_entry 应被消费");
    }
}
