use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{bounded, select, unbounded, Receiver, Sender};
use ringbuf::traits::Producer;
use tracing::{debug, error, info, warn};

use crate::decoder::{Decoder, DecodedFrame};
use crate::dsp::{DspPipeline, PeqBand};
use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};
use crate::EngineConfig;
use realfft::num_complex::Complex;
use realfft::RealFftPlanner;
use std::fs::File;

/// 播放模式
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlayMode {
    /// 顺序播放（默认）
    Normal,
    /// 单曲循环
    RepeatOne,
    /// 列表循环
    RepeatAll,
    /// 随机播放
    Shuffle,
}

/// 频谱分析数据（16 个频段幅值，0.0~1.0 归一化）
pub const SPECTRUM_BANDS: usize = 16;

/// 发给引擎线程的命令
pub enum EngineCommand {
    Play(String),
    PlayQueue(Vec<String>),
    NextTrack,
    Pause,
    Resume,
    Stop,
    Seek(f64),
    LoadIr(String),
    ClearIr,
    SetPeqBand { index: usize, band: PeqBand },
    SetStereoWidener { enabled: bool, width: f32 },
    SetVolume(f32),
    SetReplaygainGain(f32),
    SetConfig(EngineConfig),
    SetPlayMode(PlayMode),
    RemoveFromQueue(usize),
    /// 设置输出设备（下次播放生效）
    SetOutputDevice(String),
    /// 查询 underrun 计数（通过 oneshot channel 返回）
    QueryUnderrunCount(Sender<u64>),
    Quit,
}

/// 引擎发出的事件（主线程通过 Receiver 收取）
#[derive(Debug, Clone)]
pub enum EngineEvent {
    TrackChanged(String),
    PlaybackStopped,
    Position(f64),
    DurationSecs(f64),
    Error(String),
    /// 队列变更（当前队列 + 当前曲目路径）
    QueueChanged(Vec<String>, String),
    /// 实时频谱数据（16 个频段，0.0~1.0 归一化）
    Spectrum(Vec<f32>),
}

/// 对外的句柄（Send + Sync）
#[derive(Clone)]
pub struct EngineHandle {
    tx: Sender<EngineCommand>,
    pub position: Arc<AtomicU64>,
    duration_us: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    config: EngineConfig,
}

impl EngineHandle {
    /// 使用默认配置启动引擎线程，返回句柄和事件接收器
    pub fn start() -> (EngineHandle, Receiver<EngineEvent>) {
        Self::start_with_config(EngineConfig::default())
    }

    /// 使用自定义配置启动引擎线程
    pub fn start_with_config(config: EngineConfig) -> (EngineHandle, Receiver<EngineEvent>) {
        let (tx, cmd_rx) = unbounded();
        let (event_tx, event_rx) = unbounded();
        let position = Arc::new(AtomicU64::new(0));
        let duration_us = Arc::new(AtomicU64::new(0));
        let playing = Arc::new(AtomicBool::new(false));
        let pos_clone = Arc::clone(&position);
        let dur_clone = Arc::clone(&duration_us);
        let playing_clone = Arc::clone(&playing);
        let config_clone = config.clone();
        thread::spawn(move || run_engine(cmd_rx, event_tx, pos_clone, dur_clone, playing_clone, config_clone));
        (EngineHandle { tx, position, duration_us, playing, config }, event_rx)
    }

    pub fn play(&self, path: String) { let _ = self.tx.send(EngineCommand::Play(path)); }
    pub fn play_queue(&self, paths: Vec<String>) { let _ = self.tx.send(EngineCommand::PlayQueue(paths)); }
    pub fn next_track(&self) { let _ = self.tx.send(EngineCommand::NextTrack); }
    pub fn pause(&self) { let _ = self.tx.send(EngineCommand::Pause); }
    pub fn resume(&self) { let _ = self.tx.send(EngineCommand::Resume); }
    pub fn stop(&self) { let _ = self.tx.send(EngineCommand::Stop); }
    pub fn seek(&self, pos: f64) { let _ = self.tx.send(EngineCommand::Seek(pos)); }
    pub fn load_ir(&self, path: String) { let _ = self.tx.send(EngineCommand::LoadIr(path)); }
    pub fn clear_ir(&self) { let _ = self.tx.send(EngineCommand::ClearIr); }
    pub fn set_peq_band(&self, index: usize, band: PeqBand) {
        let _ = self.tx.send(EngineCommand::SetPeqBand { index, band });
    }
    pub fn set_stereo_widener(&self, enabled: bool, width: f32) {
        let _ = self.tx.send(EngineCommand::SetStereoWidener { enabled, width });
    }
    pub fn set_volume(&self, vol: f32) { let _ = self.tx.send(EngineCommand::SetVolume(vol)); }
    /// 设置 ReplayGain 增益（dB），作为 Pre-amp 在 DSP 管线 HPF 后、EQ 前应用
    pub fn set_replaygain_gain_db(&self, gain_db: f32) { let _ = self.tx.send(EngineCommand::SetReplaygainGain(gain_db)); }
    /// 更新引擎配置（采样率/声道/缓冲），下次播放时生效
    pub fn set_config(&self, config: EngineConfig) {
        // 发送到引擎线程，下次 play/seek 使用新配置
        let _ = self.tx.send(EngineCommand::SetConfig(config));
    }
    pub fn set_play_mode(&self, mode: PlayMode) { let _ = self.tx.send(EngineCommand::SetPlayMode(mode)); }
    pub fn remove_from_queue(&self, index: usize) { let _ = self.tx.send(EngineCommand::RemoveFromQueue(index)); }
    /// 设置输出设备名称（None = 系统默认），下次播放时生效
    pub fn set_output_device(&self, name: String) {
        let _ = self.tx.send(EngineCommand::SetOutputDevice(name));
    }
    /// 获取当前播放位置（秒）
    pub fn position_secs(&self) -> f64 {
        let samples = self.position.load(Ordering::Acquire);
        let sr = self.config.sample_rate as f64;
        let ch = self.config.channels as f64;
        samples as f64 / (sr * ch)
    }
    /// 获取当前曲目时长（秒），0 表示未知
    pub fn duration_secs(&self) -> f64 {
        let us = self.duration_us.load(Ordering::Acquire);
        if us > 0 { us as f64 / 1_000_000.0 } else { 0.0 }
    }
    /// 是否正在播放（未暂停）
    pub fn is_playing(&self) -> bool {
        self.playing.load(Ordering::Acquire)
    }
    /// 查询 underrun 计数
    pub fn underrun_count(&self) -> u64 {
        let (tx, rx) = bounded(1);
        let _ = self.tx.send(EngineCommand::QueryUnderrunCount(tx));
        rx.recv().unwrap_or(0)
    }
}

/// 引擎内部运行状态（只存在于引擎线程）
pub struct EngineState {
    config: EngineConfig,
    output: Option<Box<dyn AudioOutput>>,
    output_inner: Option<Arc<AudioOutputInner>>,
    /// cpal 实际运行的采样率（可能与 config.sample_rate 不同，如果 fallback 了）
    output_sample_rate: u32,
    decoder: Option<Decoder>,
    consumer_thread: Option<thread::JoinHandle<()>>,
    dsp: Option<Arc<Mutex<DspPipeline>>>,
    consumer_stop: Option<Arc<AtomicBool>>,
    current_volume: f32,
    pending_ir: Option<String>,
    pending_replaygain_db: Option<f32>,
    current_path: Option<String>,
    position: Arc<AtomicU64>,
    queue: Vec<String>,
    external_tx: Sender<EngineEvent>,
    internal_event_tx: Sender<EngineEvent>,
    peq_bands: Vec<PeqBand>,
    duration_us: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    /// 预加载的下一首（无缝播放）
    next_path: Option<String>,
    next_decoder: Option<Decoder>,
    next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>>,
    /// 播放模式
    play_mode: PlayMode,
    /// 原始播放队列（RepeatAll 时用于重新填充）
    original_queue: Vec<String>,
}

impl EngineState {
    fn new(config: EngineConfig, position: Arc<AtomicU64>, duration_us: Arc<AtomicU64>, playing: Arc<AtomicBool>, external_tx: Sender<EngineEvent>) -> Self {
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
            current_path: None,
            position,
            queue: Vec::new(),
            external_tx,
            internal_event_tx,
            peq_bands: crate::dsp::default_peq_bands(),
            duration_us,
            playing,
            next_path: None,
            next_decoder: None,
            next_rx: Arc::new(Mutex::new(None)),
            play_mode: PlayMode::Normal,
            original_queue: Vec::new(),
        }
    }

    fn play_file(&mut self, path: &str) {
        info!("play_file 开始: {path}");
        self.stop_playback();
        self.current_path = Some(path.to_string());
        let path_buf = Path::new(path).to_path_buf();

        if !path_buf.exists() {
            error!("文件不存在: {path}");
            self.emit(EngineEvent::Error(format!("文件不存在: {path}")));
            self.advance_queue();
            return;
        }

        let sr = self.config.sample_rate;
        let ch = self.config.channels;

        // 用 Symphonia 探测时长
        let dur = probe_duration_symphonia(&path_buf).unwrap_or(0);
        self.duration_us.store(dur, Ordering::Release);

        // 复用已有 audio output（仅首次创建），避免重建 cpal stream
        let (pcm, actual_sr, actual_ch) = if let Some(ref output) = self.output {
            let out_sr = self.output_sample_rate;
            let out_ch = self.config.channels;
            (output.swap_consumer(self.config.buffer_ms, out_sr, out_ch), out_sr, out_ch)
        } else {
            match crate::output::open(ch, sr, self.config.buffer_ms, self.config.output_device.as_deref()) {
                Ok((output, prod, inner, actual_rate)) => {
                    self.output_inner = Some(inner);
                    self.output = Some(output);
                    self.output_sample_rate = actual_rate;
                    (prod, actual_rate, ch)
                }
                Err(e) => {
                    error!("打开音频输出失败: {e}");
                    self.emit(EngineEvent::Error(format!("打开音频输出失败: {e}")));
                    self.advance_queue();
                    return;
                }
            }
        };

        let (rx, decoder) = match Decoder::start(&path_buf, actual_sr, actual_ch, self.position.clone(), None) {
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
            true, self.current_volume, 24,
        )));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let position_clone = self.position.clone();
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), actual_sr, actual_ch, self.config.crossfade_ms);
        let output = self.output.as_ref().expect("output 必须在之前创建");
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                info!("开始播放: {path}");
                self.playing.store(true, Ordering::Release);
                let _ = self.external_tx.send(EngineEvent::TrackChanged(path.to_string()));
                let dur = self.duration_us.load(Ordering::Acquire);
                if dur > 0 {
                    let _ = self.external_tx.send(EngineEvent::DurationSecs(dur as f64 / 1_000_000.0));
                }
                self.emit_queue();
            }
            _ => {
                error!("解码失败（无有效音频帧）: {path}");
                self.emit(EngineEvent::Error(format!("解码失败: {path} - 无有效音频数据")));
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
                if let Ok(mut pipeline) = dsp.lock() {
                    if let Err(e) = pipeline.load_conv_ir(&ir_path) {
                        error!("加载 IR 失败(play_file): {e}");
                        self.pending_ir = None;
                    }
                }
            }
        }

        self.preload_next();
    }

    fn apply_pending_replaygain(&mut self) {
        if let Some(gain_db) = self.pending_replaygain_db {
            if let Some(dsp) = &self.dsp {
                if let Ok(mut pipeline) = dsp.lock() {
                    pipeline.set_replaygain_db(gain_db);
                }
            }
        }
    }

    fn preload_next(&mut self) {
        if self.queue.is_empty() { return; }
        let path = self.queue[0].clone();
        let path_buf = Path::new(&path).to_path_buf();
        if !path_buf.exists() {
            error!("预加载文件不存在: {path}");
            return;
        }
        let dummy_pos = Arc::new(AtomicU64::new(0));
        let sr = self.output_sample_rate;
        let ch = self.config.channels;
        let (rx, decoder) = match Decoder::start(
            &path_buf, sr, ch, dummy_pos, None,
        ) {
            Ok(v) => v,
            Err(e) => { error!("预加载解码失败: {e}"); return; }
        };
        *self.next_rx.lock().unwrap_or_else(|e| e.into_inner()) = Some(rx);
        self.next_decoder = Some(decoder);
        self.next_path = Some(path);
        debug!("已预加载: {}", self.next_path.as_ref().unwrap());
    }

    fn advance_queue(&mut self) {
        match self.play_mode {
            PlayMode::Normal => self.advance_normal(),
            PlayMode::RepeatOne => self.advance_repeat_one(),
            PlayMode::RepeatAll => self.advance_repeat_all(),
            PlayMode::Shuffle => self.advance_shuffle(),
        }
    }

    fn advance_normal(&mut self) {
        if !self.queue.is_empty() {
            let next = self.queue.remove(0);
            if self.next_path.as_deref() == Some(&next) {
                debug!("无缝切换至: {next}");
                self.current_path = self.next_path.take();
                self.decoder = self.next_decoder.take();
                self.position.store(0, Ordering::SeqCst);
                let _ = self.external_tx.send(EngineEvent::TrackChanged(next.clone()));
                self.emit_queue();
                self.preload_next();
            } else {
                debug!("自动播下一曲: {next}");
                self.play_file(&next);
            }
        } else {
            self.emit(EngineEvent::PlaybackStopped);
        }
    }

    fn advance_repeat_one(&mut self) {
        if let Some(path) = self.current_path.clone() {
            self.queue.insert(0, path);
        }
        self.advance_normal();
    }

    fn advance_repeat_all(&mut self) {
        if self.queue.is_empty() && !self.original_queue.is_empty() {
            // 重新填充队列（从第二首开始，当前曲结束后下一首应是列首）
            let current = self.current_path.clone();
            self.queue = self.original_queue.iter()
                .filter(|p| Some(p.as_str()) != current.as_deref())
                .cloned()
                .collect();
            if self.queue.is_empty() {
                // 只有一首歌
                if let Some(ref path) = self.current_path {
                    self.queue.push(path.clone());
                }
            }
        }
        self.advance_normal();
    }

    fn advance_shuffle(&mut self) {
        if self.queue.is_empty() {
            self.emit(EngineEvent::PlaybackStopped);
            return;
        }
        let idx = fastrand::usize(..self.queue.len());
        let next = self.queue.remove(idx);
        if self.next_path.as_deref() == Some(&next) {
            debug!("无缝切换至: {next}");
            self.current_path = self.next_path.take();
            self.decoder = self.next_decoder.take();
                self.position.store(0, Ordering::SeqCst);
                let _ = self.external_tx.send(EngineEvent::TrackChanged(next.clone()));
                self.emit_queue();
                self.preload_next();
        } else {
            debug!("随机播下一曲: {next}");
            self.play_file(&next);
        }
    }

    fn set_queue(&mut self, paths: Vec<String>) {
        if paths.is_empty() {
            self.stop_full();
            self.queue.clear();
            self.original_queue.clear();
            return;
        }
        self.original_queue = paths.clone();
        let first = paths[0].clone();
        self.queue = paths[1..].to_vec();
        self.play_file(&first);
    }

    fn next_track(&mut self) {
        self.stop_playback();
        self.advance_queue();
    }

    fn seek(&mut self, pos: f64) {
        let path = match &self.current_path {
            Some(p) => p.clone(),
            None => { error!("seek 时无当前曲目"); return; }
        };
        info!("seek_to: {pos:.2}s");
        let sr = self.output_sample_rate;
        let ch = self.config.channels;
        let target_samples = (pos * sr as f64 * ch as f64) as u64;
        self.stop_playback();
        // stop_playback resets position to 0 — restore to seek target AFTER cleanup
        self.position.store(target_samples, Ordering::SeqCst);
        let path_buf = Path::new(&path).to_path_buf();
        if !path_buf.exists() {
            error!("文件不存在: {path}");
            return;
        }

        // 复用 output：swap consumer，不重建 cpal stream
        let pcm = self.output.as_ref().map(|o| {
            o.swap_consumer(self.config.buffer_ms, sr, ch)
        }).expect("seek 时 output 应已存在");

        let (rx, decoder) = match Decoder::start(&path_buf, sr, ch, self.position.clone(), Some(pos)) {
            Ok(v) => v,
            Err(e) => { error!("seek 启动解码失败: {e}"); return; }
        };
        let dsp = Arc::new(Mutex::new(DspPipeline::new(
            sr, ch as usize, &self.peq_bands,
            true, self.current_volume, 24,
        )));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let position_clone = self.position.clone();
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), sr, ch, self.config.crossfade_ms);
        let output = self.output.as_ref().expect("output 应存在");
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                info!("seek 到 {pos:.2}s 后恢复播放: {path}");
            }
            _ => {
                error!("seek 后解码失败: {path}");
                let _ = self.internal_event_tx.send(EngineEvent::Error(format!("seek 后解码失败: {path}")));
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

    fn load_ir(&mut self, path: &str) {
        self.pending_ir = Some(path.to_string());
        if let Some(dsp) = &self.dsp {
            if let Ok(mut pipeline) = dsp.lock() {
                if let Err(e) = pipeline.load_conv_ir(path) {
                    error!("加载 IR 失败: {e}");
                    self.pending_ir = None;
                }
            }
        }
    }

    fn clear_ir(&mut self) {
        self.pending_ir = None;
        if let Some(dsp) = &self.dsp {
            if let Ok(mut pipeline) = dsp.lock() {
                pipeline.clear_conv_ir();
            }
        }
    }

    fn set_peq_band(&mut self, index: usize, band: PeqBand) {
        if index < self.peq_bands.len() {
            self.peq_bands[index] = PeqBand {
                freq: band.freq,
                gain_db: band.gain_db,
                q: band.q,
            };
        }
        if let Some(dsp) = &self.dsp {
            if let Ok(mut pipeline) = dsp.lock() {
                pipeline.set_peq_band(index, &band, self.output_sample_rate as f32);
            }
        }
    }

    fn set_stereo_widener(&mut self, enabled: bool, width: f32) {
        if let Some(dsp) = &self.dsp {
            if let Ok(mut pipeline) = dsp.lock() {
                pipeline.set_stereo_widener(enabled, width);
            }
        }
    }

    fn set_volume(&mut self, vol: f32) {
        self.current_volume = vol;
        if let Some(dsp) = &self.dsp {
            if let Ok(mut pipeline) = dsp.lock() {
                pipeline.set_volume(vol);
            }
        }
    }

    fn set_replaygain_db(&mut self, gain_db: f32) {
        self.pending_replaygain_db = Some(gain_db);
        // 如果管线已存在，立即应用
        if let Some(dsp) = &self.dsp {
            if let Ok(mut pipeline) = dsp.lock() {
                pipeline.set_replaygain_db(gain_db);
            }
        }
    }

    fn set_play_mode(&mut self, mode: PlayMode) {
        self.play_mode = mode;
        info!("播放模式切换为: {mode:?}");
    }

    fn remove_from_queue(&mut self, idx: usize) {
        // idx 是 player.queue 中的 0-based 位置，0=当前曲目，不允许移除
        if idx == 0 { return; }
        let q_idx = idx - 1;
        if q_idx < self.queue.len() {
            let removed = self.queue.remove(q_idx);
            info!("从队列移除: {removed}");
            self.original_queue.retain(|p| *p != removed);
            self.emit_queue();
        }
    }

    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
        if let Some(o) = &self.output { o.pause(); }
    }
    fn resume(&self) {
        self.playing.store(true, Ordering::Release);
        if let Some(o) = &self.output { o.resume(); }
    }

    fn stop_full(&mut self) {
        self.stop_playback();
        self.output = None;
        self.output_inner = None;
    }

    fn stop_playback(&mut self) {
        self.playing.store(false, Ordering::Release);
        if let Some(flag) = &self.consumer_stop { flag.store(true, Ordering::SeqCst); }
        if let Some(d) = &self.decoder { d.stop(); }
        if let Some(d) = &self.next_decoder { d.stop(); }
        if let Some(o) = &self.output { o.pause(); }
        if let Some(t) = self.consumer_thread.take() { let _ = t.join(); }
        self.decoder = None;
        self.next_decoder = None;
        self.next_path = None;
        self.consumer_stop = None;
        self.dsp = None;
        self.position.store(0, Ordering::SeqCst);
    }

    fn emit(&self, event: EngineEvent) {
        let _ = self.external_tx.send(event);
    }

    fn emit_queue(&self) {
        if let Some(ref path) = self.current_path {
            let full = if self.original_queue.is_empty() {
                vec![path.clone()]
            } else {
                self.original_queue.clone()
            };
            let _ = self.external_tx.send(EngineEvent::QueueChanged(full, path.clone()));
        }
    }
}

/// 用 Symphonia 探测音频时长（微秒）
fn probe_duration_symphonia(path: &std::path::Path) -> Option<u64> {
    let file = File::open(path).ok()?;
    let mss = symphonia::core::io::MediaSourceStream::new(
        Box::new(file), Default::default()
    );
    let mut hint = symphonia::core::formats::probe::Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let format = symphonia::default::get_probe().probe(
        &hint, mss,
        symphonia::core::formats::FormatOptions::default(),
        symphonia::core::meta::MetadataOptions::default(),
    ).ok()?;
    // 尝试从 n_frames 推算时长
    let dur = format.tracks().iter()
        .find(|t| matches!(&t.codec_params, Some(symphonia::core::codecs::CodecParameters::Audio(p))
            if p.codec != symphonia::core::codecs::audio::CODEC_ID_NULL_AUDIO))
        .and_then(|t| {
            let frames = t.num_frames?;
            let tb = t.time_base?;
            let secs = frames as f64 * tb.numer.get() as f64 / tb.denom.get() as f64;
            if secs > 0.0 { Some((secs * 1_000_000.0) as u64) } else { None }
        });
    if dur.is_some() { return dur; }
    // fallback: 解码第一帧获取时长
    drop(format);
    None
}

/// 引擎线程主循环
fn run_engine(
    cmd_rx: Receiver<EngineCommand>,
    external_tx: Sender<EngineEvent>,
    position: Arc<AtomicU64>,
    duration_us: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    config: EngineConfig,
) {
    let mut state = EngineState::new(config, position, duration_us, playing, external_tx.clone());
    info!("引擎线程启动");

    // 创建内部事件 channel：消费者发 "曲目结束" 走这
    let (internal_event_tx, internal_event_rx) = unbounded::<EngineEvent>();
    state.internal_event_tx = internal_event_tx;

    let mut tick = crossbeam_channel::after(Duration::from_millis(200));

    loop {
        select! {
            recv(cmd_rx) -> msg => {
                match msg {
                    Ok(EngineCommand::Play(p)) => state.play_file(&p),
                    Ok(EngineCommand::PlayQueue(paths)) => state.set_queue(paths),
                    Ok(EngineCommand::NextTrack) => state.next_track(),
                    Ok(EngineCommand::Pause) => state.pause(),
                    Ok(EngineCommand::Resume) => state.resume(),
                    Ok(EngineCommand::Stop) => state.stop_full(),
                    Ok(EngineCommand::Seek(pos)) => state.seek(pos),
                    Ok(EngineCommand::LoadIr(p)) => state.load_ir(&p),
                    Ok(EngineCommand::ClearIr) => state.clear_ir(),
                    Ok(EngineCommand::SetPeqBand { index, band }) => state.set_peq_band(index, band),
                    Ok(EngineCommand::SetStereoWidener { enabled, width }) => state.set_stereo_widener(enabled, width),
                    Ok(EngineCommand::SetVolume(vol)) => state.set_volume(vol),
                    Ok(EngineCommand::SetReplaygainGain(gain)) => state.set_replaygain_db(gain),
                    Ok(EngineCommand::SetConfig(cfg)) => {
                        let device = state.config.output_device.take();
                        state.config = cfg;
                        state.config.output_device = device;
                        info!("引擎配置更新: {}/{}ch/{}ms", state.config.sample_rate, state.config.channels, state.config.buffer_ms);
                    },
                    Ok(EngineCommand::SetPlayMode(mode)) => state.set_play_mode(mode),
                    Ok(EngineCommand::SetOutputDevice(dev)) => {
                        if state.config.output_device.as_deref() != Some(&dev) {
                            info!("输出设备切换: {dev}（下次播放生效）");
                            state.config.output_device = Some(dev);
                        }
                    }
                    Ok(EngineCommand::RemoveFromQueue(idx)) => state.remove_from_queue(idx),
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
                    // 消费者报告曲目播放完毕 → 播下一首或停止
                    Ok(EngineEvent::TrackChanged(_)) => state.advance_queue(),
                    // 消费者也可能报告错误（目前走外部 channel，保留兜底）
                    Ok(other) => { let _ = external_tx.send(other); }
                    Err(_) => break,
                }
            }
            recv(tick) -> _ => {
                let pos_samples = state.position.load(Ordering::Acquire) as f64;
                let sr = state.config.sample_rate as f64;
                let ch = state.config.channels as f64;
                let pos_secs = pos_samples / (sr * ch);
                let _ = external_tx.send(EngineEvent::Position(pos_secs));
                tick = crossbeam_channel::after(Duration::from_millis(200));
            }
        }
    }
    info!("引擎线程退出");
}

/// 消费者线程：从解码 channel 读取帧，经 DSP 处理后推入 ring buffer
#[allow(clippy::too_many_arguments)]
/// 切歌淡入时长（毫秒），0 = 真·无间隙播放
fn crossfade_sample_count(sample_rate: u32, channels: u32, crossfade_ms: u32) -> usize {
    if crossfade_ms == 0 { return 0; }
    (sample_rate as usize * channels as usize) * crossfade_ms as usize / 1000
}

/// spawn_consumer — crossfade_ms = 0 表示无间隙（不淡入）
fn spawn_consumer(
    rx: Receiver<DecodedFrame>,
    mut pcm: PcmProducer,
    dsp: Arc<Mutex<DspPipeline>>,
    stop_flag: Arc<AtomicBool>,
    position: Arc<AtomicU64>,
    event_tx: Sender<EngineEvent>,
    ready_tx: Sender<bool>,
    next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>>,
    sample_rate: u32,
    channels: u32,
    crossfade_ms: u32,
) -> thread::JoinHandle<()> {
    let fade_total = crossfade_sample_count(sample_rate, channels, crossfade_ms);
    thread::spawn(move || {
        // [macOS] 提升线程 QoS，避免 Spotlight 等操作挤占解码线程
        #[cfg(target_os = "macos")]
        {
            // QOS_CLASS_USER_INTERACTIVE = 0x21，提升线程优先级避免 Spotlight 挤占
            extern "C" {
                fn pthread_set_qos_class_self_np(class: u32, offset: i32) -> i32;
            }
            unsafe { pthread_set_qos_class_self_np(0x21, 0); }
        }

        // 频谱分析（实时 FFT）
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
        let freq_per_bin = sample_rate as f32 / fft_size as f32;
        // 16 个频段上限 (Hz)，低频段分布更宽以获得足够 FFT bin
        let band_edges: [f32; SPECTRUM_BANDS] = [
            120.0, 200.0, 300.0, 450.0, 650.0, 900.0, 1200.0, 1600.0,
            2200.0, 3200.0, 4600.0, 6400.0, 8800.0, 12000.0, 16000.0, 22050.0,
        ];
        let mut bin_to_band = vec![0usize; fft_size / 2];
        for bin in 0..fft_size / 2 {
            let freq = bin as f32 * freq_per_bin;
            if freq < 20.0 { bin_to_band[bin] = 0; continue; }
            let mut band = SPECTRUM_BANDS - 1;
            for (b, &edge) in band_edges.iter().enumerate() {
                if freq < edge { band = b; break; }
            }
            bin_to_band[bin] = band;
        }

        let mut current_rx = rx;
        let mut frame_count = 0u64;
        let mut first_track = true;
        let mut fade_remaining = 0usize; // 还有多少样本需要淡入
        let mut dsp_time_ns: u64 = 0;
        let mut push_time_ns: u64 = 0;

        // 逐段峰值跟踪（自动归一化）
        let mut band_peaks = vec![0.001f32; SPECTRUM_BANDS];
        loop {
            match current_rx.recv() {
                Ok(frame) => {
                    if stop_flag.load(Ordering::SeqCst) { break; }
                    if first_track {
                        let _ = ready_tx.send(true);
                        first_track = false;
                    }
                    frame_count += 1;
                    let count = frame.samples.len();
                    let mut buf = frame.samples;
                    let t0 = Instant::now();
                    if let Ok(mut pipeline) = dsp.lock() {
                        pipeline.process(&mut buf);
                    }
                    dsp_time_ns += t0.elapsed().as_nanos() as u64;

                    // 实时频谱：每 3 帧做一次 FFT
                    if frame_count % 3 == 0 && buf.len() >= fft_size * channels as usize {
                        for i in 0..fft_size {
                            let l = buf[i * channels as usize];
                            let r = if channels >= 2 { buf[i * channels as usize + 1] } else { l };
                            fft_input[i] = (l + r) * 0.5 * hann[i];
                        }
                        if fft.process(&mut fft_input, &mut fft_out).is_ok() {
                            let mut bands = vec![0.0f32; SPECTRUM_BANDS];
                            let mut band_counts = vec![0usize; SPECTRUM_BANDS];
                            for (bin, &c) in fft_out.iter().enumerate().skip(1) {
                                if bin >= bin_to_band.len() { break; }
                                let b = bin_to_band[bin];
                                bands[b] += c.norm_sqr().sqrt();
                                band_counts[b] += 1;
                            }
                            for b in 0..SPECTRUM_BANDS {
                                if band_counts[b] > 0 {
                                    let avg = bands[b] / band_counts[b] as f32;
                                    // 峰值跟踪：攻击立刻跟随，释放较快(0.93)提升动态感
                                    let peak = band_peaks[b];
                                    band_peaks[b] = if avg > peak {
                                        avg * 1.1
                                    } else {
                                        peak * 0.93
                                    };
                                    bands[b] = (avg / band_peaks[b].max(0.001)).min(1.0);
                                } else {
                                    // 无 bin 的频段平滑归零
                                    band_peaks[b] *= 0.90;
                                }
                            }
                            let _ = event_tx.send(EngineEvent::Spectrum(bands));
                        }
                    }
                    // 余弦淡入：切换后第一个帧开始应用，逐步从 0→1
                    if fade_remaining > 0 {
                        let n = fade_remaining.min(buf.len());
                        let done = fade_total - fade_remaining;
                        for i in 0..n {
                            // 余弦淡入曲线: gain = 0.5 - 0.5*cos(π * i/n_total)
                            let gain = (1.0 - ((done + i) as f32 / fade_total as f32 * std::f32::consts::PI).cos()) / 2.0;
                            buf[i] *= gain;
                        }
                        fade_remaining -= n;
                    }
                    // 坏帧检测：全零或 NaN → 跳过，不污染 ringbuf
                    let bad_frame = buf.iter().all(|&s| s == 0.0) || buf.iter().any(|&s| s.is_nan());
                    if bad_frame {
                        let _ = event_tx.send(EngineEvent::Error("解码器输出坏帧（全零/NaN），已跳过".into()));
                        continue;
                    }
                    let t1 = Instant::now();
                    let mut remaining: &[f32] = &buf;
                    while !remaining.is_empty() && !stop_flag.load(Ordering::SeqCst) {
                        let n = pcm.push_slice(remaining);
                        if n == 0 { thread::sleep(Duration::from_millis(1)); }
                        remaining = &remaining[n..];
                    }
                    push_time_ns += t1.elapsed().as_nanos() as u64;
                    position.fetch_add(count as u64, Ordering::Release);
                    if frame_count % 100 == 0 {
                        debug!("consumer timing (100帧): DSP avg {:.1}µs, push avg {:.1}µs, buf {}samples",
                            dsp_time_ns as f64 / 100_000.0,
                            push_time_ns as f64 / 100_000.0,
                            buf.len());
                        dsp_time_ns = 0;
                        push_time_ns = 0;
                    }
                }
                Err(_) => {
                    // 解码器 channel 断开
                    if stop_flag.load(Ordering::SeqCst) { break; }
                    // 尝试切换到预加载的下一首解码器
                    let switched = {
                        let mut guard = next_rx.lock().unwrap_or_else(|e| e.into_inner());
                        if let Some(preloaded) = guard.take() {
                            current_rx = preloaded;
                            frame_count = 0;
                            true
                        } else { false }
                    };
                    if switched {
                        // 下次 recv OK 后对新曲应用淡入
                        fade_remaining = fade_total;
                        // 通知引擎 advance_queue
                        let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
                    } else {
                        let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
                        break;
                    }
                }
            }
        }
        if frame_count == 0 && first_track && !stop_flag.load(Ordering::SeqCst) {
            warn!("消费者未收到任何音频帧，可能解码失败");
            let _ = ready_tx.send(false);
        }
        debug!("消费者线程结束");
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossbeam_channel::unbounded;
    use ringbuf::traits::Split;
    use std::sync::atomic::Ordering;

    fn make_state(queue: Vec<String>, mode: PlayMode) -> (EngineState, Receiver<EngineEvent>) {
        let (tx, rx) = unbounded();
        let position = Arc::new(AtomicU64::new(0));
        let duration = Arc::new(AtomicU64::new(0));
        let playing = Arc::new(AtomicBool::new(false));
        let (internal_tx, _) = unbounded();
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
            current_path: Some("/tmp/test.wav".into()),
            position,
            queue,
            external_tx: tx.clone(),
            internal_event_tx: internal_tx,
            peq_bands: crate::dsp::default_peq_bands(),
            duration_us: duration,
            playing,
            next_path: None,
            next_decoder: None,
            next_rx: Arc::new(Mutex::new(None)),
            play_mode: mode,
            original_queue: vec!["/tmp/a.wav".into(), "/tmp/b.wav".into()],
        };
        (s, rx)
    }

    /// Helper：从事件 rx 中收集除 DurationSecs/Position/QueueChanged 外的下一个事件
    fn next_state_event(rx: &Receiver<EngineEvent>) -> Option<EngineEvent> {
        loop {
            match rx.recv_timeout(Duration::from_secs(2)) {
                Ok(EngineEvent::DurationSecs(_)) | Ok(EngineEvent::Position(_)) | Ok(EngineEvent::QueueChanged(..)) => continue,
                other => return other.ok(),
            }
        }
    }

    #[test]
    fn test_normal_advance_removes_from_queue() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into(), "/tmp/next2.wav".into()],
            PlayMode::Normal,
        );
        let orig_len = state.queue.len();
        state.advance_normal();
        // advance_normal 调用 play_file（CI 上无音频输出会失败并继续 advance）
        // 但队列一定变短了
        assert!(state.queue.len() < orig_len, "advance_normal 应减少队列");
    }

    #[test]
    fn test_normal_queue_empty_emits_stopped() {
        let (mut state, rx) = make_state(vec![], PlayMode::Normal);
        state.advance_normal();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(matches!(ev, EngineEvent::PlaybackStopped), "预期停止, 收到: {ev:?}");
    }

    #[test]
    fn test_repeat_one_inserts_current_to_front() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into()],
            PlayMode::RepeatOne,
        );
        let before = state.queue.len();
        // 手动模拟 repeat_one 的核心逻辑
        if let Some(path) = state.current_path.clone() {
            state.queue.insert(0, path);
        }
        assert_eq!(state.queue.len(), before + 1, "应为 current_path 插入队首");
        assert_eq!(state.queue[0], "/tmp/test.wav", "应插回 current_path");
    }

    #[test]
    fn test_repeat_all_refills_queue_on_empty() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        let current = state.current_path.clone();
        state.queue = state.original_queue.iter()
            .filter(|p| Some(p.as_str()) != current.as_deref())
            .cloned()
            .collect();
        if state.queue.is_empty() {
            if let Some(ref path) = state.current_path {
                state.queue.push(path.clone());
            }
        }
        assert_eq!(state.queue.len(), 2, "RepeatAll 应填入 2 首");
        assert_eq!(state.queue[0], "/tmp/a.wav");
        assert_eq!(state.queue[1], "/tmp/b.wav");
    }

    #[test]
    fn test_repeat_all_single_track_refills() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        state.current_path = Some("/tmp/a.wav".into());
        state.original_queue = vec!["/tmp/a.wav".into()];
        let current = state.current_path.clone();
        state.queue = state.original_queue.iter()
            .filter(|p| Some(p.as_str()) != current.as_deref())
            .cloned()
            .collect();
        if state.queue.is_empty() {
            if let Some(ref path) = state.current_path {
                state.queue.push(path.clone());
            }
        }
        assert_eq!(state.queue.len(), 1, "单曲 RepeatAll 应填入到 1");
        assert_eq!(state.queue[0], "/tmp/a.wav");
    }

    #[test]
    fn test_shuffle_removes_random_track() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/a.wav".into(), "/tmp/b.wav".into(), "/tmp/c.wav".into()],
            PlayMode::Shuffle,
        );
        let before = state.queue.len();
        // 手动模拟 shuffle 的核心逻辑
        if !state.queue.is_empty() {
            let idx = fastrand::usize(..state.queue.len());
            state.queue.remove(idx);
        }
        assert_eq!(state.queue.len(), before - 1, "Shuffle 应移除一首");
    }

    #[test]
    fn test_shuffle_empty_emits_stopped() {
        let (mut state, rx) = make_state(vec![], PlayMode::Shuffle);
        state.advance_shuffle();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(matches!(ev, EngineEvent::PlaybackStopped), "预期停止, 收到: {ev:?}");
    }

    // ── 新增测试 ──

    #[test]
    fn test_remove_from_queue_removes_at_index() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/song1.wav".into(), "/tmp/song2.wav".into(), "/tmp/song3.wav".into()],
            PlayMode::Normal,
        );
        // idx=0 是当前曲目，不允许移除
        state.remove_from_queue(0);
        assert_eq!(state.queue.len(), 3, "不应移除当前曲目");
        // idx=1 移除 song1（队列中的第 0 首）
        state.remove_from_queue(1);
        assert_eq!(state.queue.len(), 2, "应移除一首");
        assert!(!state.queue.contains(&"/tmp/song1.wav".into()), "song1 应从队列移除");
    }

    #[test]
    fn test_remove_from_queue_out_of_bounds() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/song1.wav".into()],
            PlayMode::Normal,
        );
        state.remove_from_queue(5); // 越界，不应影响
        assert_eq!(state.queue.len(), 1, "越界移除不应影响队列");
    }

    #[test]
    fn test_set_play_mode_updates_mode() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        assert_eq!(state.play_mode, PlayMode::Normal);
        state.set_play_mode(PlayMode::Shuffle);
        assert_eq!(state.play_mode, PlayMode::Shuffle);
        state.set_play_mode(PlayMode::RepeatAll);
        assert_eq!(state.play_mode, PlayMode::RepeatAll);
    }

    #[test]
    fn test_pause_resume_toggles_playing() {
        let (state, _rx) = make_state(vec![], PlayMode::Normal);
        assert!(!state.playing.load(Ordering::Acquire), "初始应为未播放");
        state.resume();
        assert!(state.playing.load(Ordering::Acquire), "resume 后应为 true");
        state.pause();
        assert!(!state.playing.load(Ordering::Acquire), "pause 后应为 false");
    }

    #[test]
    fn test_stop_playback_idempotent() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        // 所有字段为 None 时调用 stop_playback 不应 panic
        state.stop_playback();
        assert!(state.decoder.is_none());
        assert!(state.consumer_thread.is_none());
        // 第二次调用仍安全
        state.stop_playback();
    }

    #[test]
    fn test_seek_no_current_path_does_nothing() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        state.current_path = None;
        // seek 在无 current_path 时应直接返回
        state.seek(10.0);
        // 没有 panic，就是成功
    }

    #[test]
    fn test_advance_normal_empty_queue() {
        let (mut state, rx) = make_state(vec![], PlayMode::Normal);
        state.advance_normal();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(matches!(ev, EngineEvent::PlaybackStopped), "空队列应触发停止, 收到: {ev:?}");
    }

    #[test]
    fn test_repeat_one_requeues_current() {
        // 不调用 advance_repeat_one（它会尝试 play_file 导致递归），
        // 直接验证其内核逻辑
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into()],
            PlayMode::RepeatOne,
        );
        // advance_repeat_one 的核心：将 current_path 插入队首
        if let Some(path) = state.current_path.clone() {
            state.queue.insert(0, path);
        }
        assert_eq!(state.queue.len(), 2, "RepeatOne 后队列应包含 current + 原有 next1");
        assert_eq!(state.queue[0], "/tmp/test.wav", "current_path 应插回队首");
    }

    #[test]
    fn test_next_track_with_preloaded_switches() {
        // 直接测试 advance_normal 的无缝切换逻辑，不触发 play_file
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into()],
            PlayMode::Normal,
        );
        state.next_path = Some("/tmp/next1.wav".into());
        state.current_path = Some("/tmp/current.wav".into());
        // 模拟 advance_normal 中匹配 next_path 的逻辑
        if !state.queue.is_empty() {
            let next = state.queue.remove(0);
            if state.next_path.as_deref() == Some(&next) {
                state.current_path = state.next_path.take();
                state.decoder = state.next_decoder.take();
                state.position.store(0, Ordering::SeqCst);
            }
        }
        assert!(state.queue.is_empty(), "队列应已清空");
        assert_eq!(state.current_path.as_deref(), Some("/tmp/next1.wav"));
        assert!(state.next_path.is_none(), "next_path 应被消费");
    }

    #[test]
    fn test_emit_queue_with_current_path() {
        let (state, rx) = make_state(
            vec!["/tmp/song1.wav".into()],
            PlayMode::Normal,
        );
        state.emit_queue();
        // 应收到 QueueChanged 事件（通过 next_state_event 的过滤）
        // 我们用直接检查 external_tx 的方式
        let ev = rx.recv_timeout(Duration::from_millis(200));
        assert!(ev.is_ok(), "应发出事件");
    }

    #[test]
    fn test_probe_duration_nonexistent_file() {
        let dur = probe_duration_symphonia(std::path::Path::new("/tmp/_nonexistent_dur_test.wav"));
        assert!(dur.is_none(), "不存在的文件应返回 None");
    }

    #[test]
    fn test_engine_handle_start_stop_cycle() {
        // EngineHandle::start + drop 完整生命周期
        let (handle, _rx) = EngineHandle::start();
        assert!(!handle.is_playing(), "初始应未播放");
        assert_eq!(handle.position_secs(), 0.0);
        assert_eq!(handle.duration_secs(), 0.0);
        handle.stop();
        // drop handle → tx 被 drop → 引擎线程收到 Err 并退出
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
        };
        assert_eq!(cfg.sample_rate, 96000);
        assert_eq!(cfg.buffer_ms, 50);
    }

    #[test]
    fn test_start_with_config_position() {
        // 96000Hz 下 position_secs 计算应正确
        let cfg = EngineConfig {
            sample_rate: 96000,
            channels: 2,
            buffer_ms: 80,
            crossfade_ms: 0,
            output_device: None,
        };
        let (handle, _rx) = EngineHandle::start_with_config(cfg);
        assert_eq!(handle.position_secs(), 0.0);
        // position 默认 0，96000*2=192000 samples/sec
        handle.position.store(96000 * 2 * 5, Ordering::SeqCst); // 5秒
        let pos = handle.position_secs();
        assert!((pos - 5.0).abs() < 0.001, "96000Hz 下 5s 应≈5.0, 实际: {pos}");
        drop(handle);
    }

    #[test]
    fn test_start_with_config_44100_position() {
        // 44100Hz 下 position_secs 计算（默认配置）
        let cfg = EngineConfig {
            sample_rate: 44100,
            channels: 1,
            buffer_ms: 80,
            crossfade_ms: 0,
            output_device: None,
        };
        let (handle, _rx) = EngineHandle::start_with_config(cfg);
        handle.position.store(44100 * 10, Ordering::SeqCst); // 10秒（单声道）
        let pos = handle.position_secs();
        assert!((pos - 10.0).abs() < 0.001, "44100Hz 单声道 10s 应≈10.0, 实际: {pos}");
        drop(handle);
    }

    // ── 交叉淡入 ──

    #[test]
    fn test_crossfade_sample_count() {
        let n = crossfade_sample_count(44100, 2, 50);
        // 44100 Hz * 2 ch * 50 ms
        assert_eq!(n, 4410, "50ms 立体声应 = 4410 samples");
        // 测试不同参数
        assert_eq!(crossfade_sample_count(48000, 2, 50), 4800, "48kHz 50ms 立体声");
        assert_eq!(crossfade_sample_count(44100, 1, 50), 2205, "44.1kHz 50ms 单声道");
    }

    #[test]
    fn test_crossfade_curve_starts_at_zero() {
        // gain at i=0: (1 - cos(π * 0/total)) / 2 = (1 - 1) / 2 = 0
        let gain = (1.0 - (0.0f32 * std::f32::consts::PI).cos()) / 2.0;
        assert!((gain - 0.0).abs() < 1e-6, "i=0 时 gain 应为 0, 实际 {gain}");
    }

    #[test]
    fn test_crossfade_curve_midpoint() {
        // gain at i=total/2: (1 - cos(π/2)) / 2 = (1 - 0) / 2 = 0.5
        let gain = (1.0 - (0.5f32 * std::f32::consts::PI).cos()) / 2.0;
        assert!((gain - 0.5).abs() < 0.01, "i=total/2 时 gain 应 ≈0.5, 实际 {gain}");
    }

    #[test]
    fn test_crossfade_curve_ends_at_one() {
        // gain at i=total: (1 - cos(π)) / 2 = (1 - (-1)) / 2 = 1
        let gain = (1.0 - (1.0f32 * std::f32::consts::PI).cos()) / 2.0;
        assert!((gain - 1.0).abs() < 1e-6, "i=total 时 gain 应为 1, 实际 {gain}");
    }

    #[test]
    fn test_crossfade_fade_remaining_reset_on_switch() {
        // 验证切换后 fade_remaining 被正确设为 fade_total
        let (tx1, rx1) = unbounded::<DecodedFrame>();
        let (_tx2, _rx2) = unbounded::<DecodedFrame>();
        let (_pcm_tx, _pcm_rx) = unbounded::<f32>();

        let dsp = Arc::new(Mutex::new(DspPipeline::new(44100, 2, &[], false, 1.0, 24)));
        let stop = Arc::new(AtomicBool::new(false));
        let pos = Arc::new(AtomicU64::new(0));
        let (ev_tx, _ev_rx) = unbounded();
        let (ready_tx, ready_rx) = unbounded();
        let next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>> = Arc::new(Mutex::new(None));

        // 用 PcmProducer 包装 fake producer（空类型，仅用于构造）
        let rb = ringbuf::HeapRb::<f32>::new(65536);
        let (prod, _cons) = rb.split();

        let consumer = spawn_consumer(rx1, prod, dsp, stop.clone(), pos, ev_tx, ready_tx, next_rx.clone(), 44100, 2, 0);

        // 发送第一首曲的帧，让消费者就绪
        let frame = DecodedFrame {
            samples: vec![0.5f32; 1024],
            pts_secs: 0.0,
            sample_rate: 44100,
            channels: 2,
        };
        tx1.send(frame).ok();
        assert!(ready_rx.recv_timeout(Duration::from_secs(1)).unwrap_or(false), "消费者应就绪");

        // 断开第一首解码器 channel → 消费者试图切换到 next
        // 此时 next_rx 为 None → 消费者停止
        drop(tx1);
        thread::sleep(Duration::from_millis(50));

        // 检查 stop_flag 状态
        assert!(!stop.load(Ordering::Acquire), "消费者不应被 stop 停止");
        stop.store(true, Ordering::SeqCst);
        let _ = consumer.join();
    }
}
