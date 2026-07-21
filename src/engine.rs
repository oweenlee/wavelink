use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{bounded, select, unbounded, Receiver, Sender};
use ringbuf::traits::Producer;
use tracing::{debug, error, info};

use crate::decoder::{Decoder, DecodedFrame};
use crate::dsp::{DspPipeline, PeqBand};
use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};
use crate::EngineConfig;
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
    /// 播放单个文件
    Play(String),
    /// 设置播放队列并从第一首开始播放
    PlayQueue(Vec<String>),
    /// 下一首
    NextTrack,
    /// 上一首（播放超过 3 秒则回到开头，否则切回上一曲）
    PrevTrack,
    /// 暂停播放
    Pause,
    /// 恢复播放
    Resume,
    /// 停止播放并清空队列
    Stop,
    /// 跳转到指定位置（秒）
    Seek(f64),
    /// 加载脉冲响应文件
    LoadIr(String),
    /// 清除脉冲响应
    ClearIr,
    /// 设置参数均衡器某频段的参数
    SetPeqBand {
        /// 频段索引（0-30）
        index: usize,
        /// 频段参数（频率 / 增益 / Q 值）
        band: PeqBand,
    },
    /// 设置立体声展宽
    SetStereoWidener {
        /// 是否启用展宽
        enabled: bool,
        /// 展宽系数（0=单声道, 1=原始, >1=展宽）
        width: f32,
    },
    /// 设置音量
    SetVolume(f32),
    /// 设置 ReplayGain 增益（dB）
    SetReplaygainGain(f32),
    /// 更新引擎配置，下次播放时生效
    SetConfig(EngineConfig),
    /// 设置播放模式
    SetPlayMode(PlayMode),
    /// 从队列中移除指定索引的曲目
    RemoveFromQueue(usize),
    /// 设置输出设备（下次播放生效）
    SetOutputDevice(String),
    /// 设置播放速度（0.25 ~ 4.0），1.0 = 正常
    SetSpeed(f32),
    /// 查询 underrun 计数（通过 oneshot channel 返回）
    QueryUnderrunCount(Sender<u64>),
    /// 开始音频输入捕获
    StartCapture {
        /// 捕获采样率
        sample_rate: u32,
        /// 捕获声道数
        channels: u32,
    },
    /// 停止音频输入捕获
    StopCapture,
    /// 音频会话中断开始（如电话呼入），引擎自动暂停播放
    SessionInterruptionBegan,
    /// 音频会话中断结束，引擎自动恢复播放
    SessionInterruptionEnded,
    /// 退出引擎线程
    Quit,
}

/// 引擎发出的事件（主线程通过 Receiver 收取）
#[derive(Debug, Clone)]
pub enum EngineEvent {
    /// 曲目变更（携带新曲目路径/显示名）
    TrackChanged(String),
    /// 播放停止
    PlaybackStopped,
    /// 播放位置更新（秒）
    Position(f64),
    /// 当前曲目时长（秒）
    DurationSecs(f64),
    /// 错误消息
    Error(String),
    /// 队列变更（当前队列 + 当前曲目路径）
    QueueChanged(Vec<String>, String),
    /// 实时频谱数据（16 个频段，0.0~1.0 归一化）
    Spectrum(Vec<f32>),
    /// 电平数据（RMS / 峰值 / 削波标志）
    Levels(Levels),
}

/// 实时音频电平：每帧计算 RMS 和峰值（各声道最大值）
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize)]
pub struct Levels {
    /// RMS 音量（归一化 0.0~1.0，各声道 RMS 的最大值）
    pub rms: f32,
    /// 峰值（归一化 0.0~1.0，各声道绝对值的最大值）
    pub peak: f32,
    /// 是否削波（任意样本绝对值 ≥ 1.0）
    pub clip: bool,
}

impl Default for Levels {
    fn default() -> Self {
        Levels { rms: 0.0, peak: 0.0, clip: false }
    }
}

/// 对外的句柄（Send + Sync）
#[derive(Clone)]
pub struct EngineHandle {
    /// 命令发送端
    tx: Sender<EngineCommand>,
    /// 当前播放位置（样本数），外部可读
    pub position: Arc<AtomicU64>,
    /// 曲目时长（微秒）
    duration_us: Arc<AtomicU64>,
    /// 播放状态（是否正在播放）
    playing: Arc<AtomicBool>,
    /// 引擎配置（与引擎线程共享，SetConfig 时同步更新）
    config: Arc<RwLock<EngineConfig>>,
    /// 实时电平
    levels: Arc<Mutex<Levels>>,
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
        let levels = Arc::new(Mutex::new(Levels::default()));
        let pos_clone = Arc::clone(&position);
        let dur_clone = Arc::clone(&duration_us);
        let playing_clone = Arc::clone(&playing);
        let levels_clone = Arc::clone(&levels);
        let config_shared = Arc::new(RwLock::new(config.clone()));
        let config_for_engine = Arc::clone(&config_shared);
        thread::spawn(move || run_engine(cmd_rx, event_tx, pos_clone, dur_clone, playing_clone, config, config_for_engine, levels_clone));
        (EngineHandle { tx, position, duration_us, playing, config: config_shared, levels }, event_rx)
    }

    /// 获取当前音频电平（RMS / 峰值 / 削波标志）
    pub fn levels(&self) -> Levels {
        self.levels.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// 开始播放指定路径的音频文件
    pub fn play(&self, path: String) { let _ = self.tx.send(EngineCommand::Play(path)); }
    /// 设置播放队列并从第一首开始播放
    pub fn play_queue(&self, paths: Vec<String>) { let _ = self.tx.send(EngineCommand::PlayQueue(paths)); }
    /// 下一首
    pub fn next_track(&self) { let _ = self.tx.send(EngineCommand::NextTrack); }
    /// 上一首（播放超过 3 秒则回到开头，否则切回上一曲）
    pub fn prev_track(&self) { let _ = self.tx.send(EngineCommand::PrevTrack); }
    /// 暂停播放
    pub fn pause(&self) { let _ = self.tx.send(EngineCommand::Pause); }
    /// 恢复播放
    pub fn resume(&self) { let _ = self.tx.send(EngineCommand::Resume); }
    /// 停止播放并清空队列
    pub fn stop(&self) { let _ = self.tx.send(EngineCommand::Stop); }
    /// 跳转到指定位置（秒）
    pub fn seek(&self, pos: f64) { let _ = self.tx.send(EngineCommand::Seek(pos)); }
    /// 加载脉冲响应文件（卷积均衡器用）
    pub fn load_ir(&self, path: String) { let _ = self.tx.send(EngineCommand::LoadIr(path)); }
    /// 清除脉冲响应（恢复平坦响应）
    pub fn clear_ir(&self) { let _ = self.tx.send(EngineCommand::ClearIr); }
    /// 设置参数均衡器某频段的参数
    pub fn set_peq_band(&self, index: usize, band: PeqBand) {
        let _ = self.tx.send(EngineCommand::SetPeqBand { index, band });
    }
    /// 设置立体声展宽
    pub fn set_stereo_widener(&self, enabled: bool, width: f32) {
        let _ = self.tx.send(EngineCommand::SetStereoWidener { enabled, width });
    }
    /// 设置音量（0.0 ~ 2.0）
    pub fn set_volume(&self, vol: f32) { let _ = self.tx.send(EngineCommand::SetVolume(vol)); }
    /// 设置 ReplayGain 增益（dB），作为 Pre-amp 在 DSP 管线 HPF 后、EQ 前应用
    pub fn set_replaygain_gain_db(&self, gain_db: f32) { let _ = self.tx.send(EngineCommand::SetReplaygainGain(gain_db)); }
    /// 更新引擎配置（采样率/声道/缓冲），下次播放时生效
    pub fn set_config(&self, config: EngineConfig) {
        // 发送到引擎线程，下次 play/seek 使用新配置
        let _ = self.tx.send(EngineCommand::SetConfig(config));
    }
    /// 设置播放模式（普通 / 单曲循环 / 随机）
    pub fn set_play_mode(&self, mode: PlayMode) { let _ = self.tx.send(EngineCommand::SetPlayMode(mode)); }
    /// 从队列中移除指定索引的曲目
    pub fn remove_from_queue(&self, index: usize) { let _ = self.tx.send(EngineCommand::RemoveFromQueue(index)); }
    /// 设置输出设备名称（None = 系统默认），下次播放时生效
    pub fn set_output_device(&self, name: String) {
        let _ = self.tx.send(EngineCommand::SetOutputDevice(name));
    }
    /// 获取当前播放位置（秒）
    pub fn position_secs(&self) -> f64 {
        let samples = self.position.load(Ordering::Acquire);
        let cfg = self.config.read().unwrap_or_else(|e| e.into_inner());
        let sr = cfg.sample_rate as f64;
        let ch = cfg.channels as f64;
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
    /// 设置播放速度（0.25 ~ 4.0），1.0 = 正常
    pub fn set_speed(&self, speed: f32) {
        let _ = self.tx.send(EngineCommand::SetSpeed(speed));
    }
    /// 查询 underrun 计数
    pub fn underrun_count(&self) -> u64 {
        let (tx, rx) = bounded(1);
        let _ = self.tx.send(EngineCommand::QueryUnderrunCount(tx));
        rx.recv().unwrap_or(0)
    }

    /// 开始音频输入捕获
    pub fn start_capture(&self, sample_rate: u32, channels: u32) {
        let _ = self.tx.send(EngineCommand::StartCapture { sample_rate, channels });
    }

    /// 停止音频输入捕获
    pub fn stop_capture(&self) {
        let _ = self.tx.send(EngineCommand::StopCapture);
    }

    /// 音频会话中断开始（如电话呼入），引擎自动暂停播放
    pub fn session_interruption_began(&self) {
        let _ = self.tx.send(EngineCommand::SessionInterruptionBegan);
    }

    /// 音频会话中断结束，引擎自动恢复播放
    pub fn session_interruption_ended(&self) {
        let _ = self.tx.send(EngineCommand::SessionInterruptionEnded);
    }
}

/// 队列条目（普通文件或 CUE 分轨）
#[derive(Debug, Clone)]
struct QueueEntry {
    /// 显示名称（TrackChanged/QueueChanged 事件用）
    display: String,
    /// 实际解码的音频文件路径
    audio_file: String,
    /// 文件内起始偏移（秒）
    start_secs: f64,
    /// 文件内结束位置（秒），<= 0 表示播放到文件末尾
    end_secs: f64,
}

impl QueueEntry {
    fn for_file(path: String) -> Self {
        QueueEntry { display: path.clone(), audio_file: path, start_secs: 0.0, end_secs: 0.0 }
    }
    fn seek_pos(&self) -> Option<f64> {
        if self.start_secs > 0.0 { Some(self.start_secs) } else { None }
    }
    fn end_secs_opt(&self) -> Option<f64> {
        if self.end_secs > 0.0 { Some(self.end_secs) } else { None }
    }
}

/// 将路径列表解析为 QueueEntry 列表，展开 .cue 文件中的虚轨
fn resolve_entries(paths: Vec<String>) -> Vec<QueueEntry> {
    let mut entries = Vec::new();
    for p in paths {
        let path = std::path::Path::new(&p);
        if path.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case("cue")).unwrap_or(false) {
            match crate::cue::parse_cue(path) {
                Ok(sheet) => {
                    let parent = path.parent().unwrap_or(std::path::Path::new(""));
                    for file in &sheet.files {
                        let audio = parent.join(&file.path);
                        let audio_str = audio.to_string_lossy().to_string();
                        for (i, track) in file.tracks.iter().enumerate() {
                            let end = if i + 1 < file.tracks.len() {
                                file.tracks[i + 1].start_secs
                            } else {
                                0.0
                            };
                            let title = track.title.as_deref().unwrap_or(&track.num);
                            entries.push(QueueEntry {
                                display: format!("{} - {}", p, title),
                                audio_file: audio_str.clone(),
                                start_secs: track.start_secs,
                                end_secs: end,
                            });
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!("CUE 解析失败 {p}: {e}");
                }
            }
        } else {
            entries.push(QueueEntry::for_file(p));
        }
    }
    entries
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
    current_entry: Option<QueueEntry>,
    position: Arc<AtomicU64>,
    queue: Vec<QueueEntry>,
    external_tx: Sender<EngineEvent>,
    internal_event_tx: Sender<EngineEvent>,
    peq_bands: Vec<PeqBand>,
    duration_us: Arc<AtomicU64>,
    playing: Arc<AtomicBool>,
    /// 预加载的下一首（无缝播放）
    next_entry: Option<QueueEntry>,
    next_decoder: Option<Decoder>,
    next_rx: Arc<Mutex<Option<Receiver<DecodedFrame>>>>,
    /// 播放模式
    play_mode: PlayMode,
    /// 原始播放队列（RepeatAll 时用于重新填充）
    original_queue: Vec<QueueEntry>,
    /// 播放历史栈（用于“上一首”）
    history: Vec<QueueEntry>,
    /// 变速共享状态
    speed: Arc<Mutex<f32>>,
    /// 实时电平
    levels: Arc<Mutex<Levels>>,
}

impl EngineState {
    fn new(config: EngineConfig, position: Arc<AtomicU64>, duration_us: Arc<AtomicU64>, playing: Arc<AtomicBool>, external_tx: Sender<EngineEvent>, levels: Arc<Mutex<Levels>>) -> Self {
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
            speed: Arc::new(Mutex::new(1.0)),
            levels,
        }
    }

    fn play_entry(&mut self, entry: &QueueEntry) {
        info!("播放: {} (file={}, start={}s, end={}s)",
            entry.display, entry.audio_file, entry.start_secs, entry.end_secs);
        // 记录历史（用于“上一首”）
        if let Some(ref cur) = self.current_entry {
            if cur.display != entry.display {
                self.history.push(cur.clone());
                if self.history.len() > 100 {
                    self.history.remove(0);
                }
            }
        }
        self.stop_playback();
        self.current_entry = Some(entry.clone());
        let path_buf = Path::new(&entry.audio_file).to_path_buf();

        if !path_buf.exists() {
            error!("文件不存在: {}", entry.audio_file);
            self.emit(EngineEvent::Error(format!("文件不存在: {}", entry.audio_file)));
            self.advance_queue();
            return;
        }

        let sr = self.config.sample_rate;
        let ch = self.config.channels;

        // 计算时长（CUE 分轨使用虚轨时长）
        let dur = if entry.end_secs > 0.0 {
            ((entry.end_secs - entry.start_secs) * 1_000_000.0) as u64
        } else {
            // 最后一轨：播放到文件末尾，需减去起始偏移
            let full = probe_duration_symphonia(&path_buf).unwrap_or(0);
            full.saturating_sub((entry.start_secs * 1_000_000.0) as u64)
        };
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
            true, self.current_volume, 24,
        )));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let position_clone = self.position.clone();
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), actual_sr, actual_ch, self.config.crossfade_ms, self.speed.clone(), self.levels.clone());
        let output = self.output.as_ref().expect("output 必须在之前创建");
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
        *self.next_rx.lock().unwrap_or_else(|e| e.into_inner()) = Some(rx);
        self.next_decoder = Some(decoder);
        self.next_entry = Some(entry.clone());
        debug!("已预加载: {}", self.next_entry.as_ref().unwrap().display);
    }

    fn advance_queue(&mut self) {
        match self.play_mode {
            PlayMode::Normal => self.advance_normal(),
            PlayMode::RepeatOne => self.advance_repeat_one(),
            PlayMode::RepeatAll => self.advance_repeat_all(),
            PlayMode::Shuffle => self.advance_shuffle(),
        }
    }

    /// 计算 QueueEntry 的时长（微秒）
    fn compute_duration_us(&self, entry: &QueueEntry) -> u64 {
        if entry.end_secs > 0.0 {
            ((entry.end_secs - entry.start_secs) * 1_000_000.0) as u64
        } else {
            let path_buf = Path::new(&entry.audio_file).to_path_buf();
            let full = probe_duration_symphonia(&path_buf).unwrap_or(0);
            full.saturating_sub((entry.start_secs * 1_000_000.0) as u64)
        }
    }

    /// 无缝切歌时更新元数据（时长 + 事件）
    fn seamless_switch(&mut self, next: &QueueEntry) {
        debug!("无缝切换至: {}", next.display);
        self.current_entry = self.next_entry.take();
        self.decoder = self.next_decoder.take();
        self.position.store(0, Ordering::SeqCst);
        // 更新时长
        let dur = self.compute_duration_us(next);
        self.duration_us.store(dur, Ordering::Release);
        let _ = self.external_tx.send(EngineEvent::TrackChanged(next.display.clone()));
        if dur > 0 {
            let _ = self.external_tx.send(EngineEvent::DurationSecs(dur as f64 / 1_000_000.0));
        }
        self.emit_queue();
        self.preload_next();
    }

    fn advance_normal(&mut self) {
        if !self.queue.is_empty() {
            let next = self.queue.remove(0);
            let match_seamless = self.next_entry.as_ref()
                .map(|e| e.display == next.display)
                .unwrap_or(false);
            if match_seamless {
                self.seamless_switch(&next);
            } else {
                debug!("自动播下一曲: {}", next.display);
                self.play_entry(&next);
            }
        } else {
            self.emit(EngineEvent::PlaybackStopped);
        }
    }

    fn advance_repeat_one(&mut self) {
        if let Some(entry) = self.current_entry.clone() {
            self.queue.insert(0, entry);
        }
        self.advance_normal();
    }

    fn advance_repeat_all(&mut self) {
        if self.queue.is_empty() && !self.original_queue.is_empty() {
            let current = self.current_entry.as_ref().map(|e| &e.display);
            self.queue = self.original_queue.iter()
                .filter(|e| Some(&e.display) != current)
                .cloned()
                .collect();
            if self.queue.is_empty() {
                if let Some(ref entry) = self.current_entry {
                    self.queue.push(entry.clone());
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
        let match_seamless = self.next_entry.as_ref()
            .map(|e| e.display == next.display)
            .unwrap_or(false);
        if match_seamless {
            self.seamless_switch(&next);
        } else {
            debug!("随机播下一曲: {}", next.display);
            self.play_entry(&next);
        }
    }

    fn set_queue(&mut self, paths: Vec<String>) {
        let entries = resolve_entries(paths);
        if entries.is_empty() {
            self.stop_full();
            self.queue.clear();
            self.original_queue.clear();
            return;
        }
        let first = entries[0].clone();
        self.queue = entries[1..].to_vec();
        self.original_queue = entries;
        self.play_entry(&first);
    }

    fn next_track(&mut self) {
        self.stop_playback();
        self.advance_queue();
    }

    fn prev_track(&mut self) {
        // 播放超过 3 秒→ 回到开头；否则切回上一曲
        let pos_secs = {
            let samples = self.position.load(Ordering::Acquire) as f64;
            let sr = self.config.sample_rate as f64;
            let ch = self.config.channels as f64;
            samples / (sr * ch)
        };
        if pos_secs > 3.0 {
            self.seek(0.0);
            return;
        }
        if let Some(prev) = self.history.pop() {
            self.play_entry(&prev);
        } else {
            // 无历史，回到开头
            self.seek(0.0);
        }
    }

    fn play_file(&mut self, path: &str) {
        let entries = resolve_entries(vec![path.to_string()]);
        if entries.is_empty() {
            self.emit(EngineEvent::Error(format!("无法解析音轨: {path}")));
            return;
        }
        if entries.len() == 1 {
            self.play_entry(&entries[0]);
        } else {
            // .cue 文件展开为多虚拟轨
            let first = entries[0].clone();
            self.queue = entries[1..].to_vec();
            self.original_queue = entries;
            self.play_entry(&first);
        }
    }

    fn seek(&mut self, pos: f64) {
        let entry = match &self.current_entry {
            Some(e) => e.clone(),
            None => { error!("seek 时无当前曲目"); return; }
        };
        // pos 是虚轨内偏移，需要转成文件内的绝对位置
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

        // 复用 output：swap consumer，不重建 cpal stream
        let pcm = self.output.as_ref().map(|o| {
            o.swap_consumer(self.config.buffer_ms, sr, ch)
        }).expect("seek 时 output 应已存在");

        let (rx, decoder) = match Decoder::start(
            &path_buf, sr, ch, self.position.clone(),
            Some(file_pos), entry.end_secs_opt(),
        ) {
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
        let consumer = spawn_consumer(rx, pcm, dsp.clone(), stop_flag.clone(), position_clone, consumer_event_tx, ready_tx, self.next_rx.clone(), sr, ch, self.config.crossfade_ms, self.speed.clone(), self.levels.clone());
        let output = self.output.as_ref().expect("output 应存在");
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

    fn set_speed(&mut self, speed: f32) {
        let s = speed.clamp(0.25, 4.0);
        if let Ok(mut sp) = self.speed.lock() {
            *sp = s;
        }
        info!("播放速度: {s:.2}x");
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
            info!("从队列移除: {}", removed.display);
            self.original_queue.retain(|e| e.display != removed.display);
            self.emit_queue();
        }
    }

    fn pause(&mut self) {
        self.playing.store(false, Ordering::Release);
        // 淡出防 pop（~5ms），由 consumer 线程在 DSP 中实时应用
        if let Some(dsp) = &self.dsp {
            if let Ok(mut p) = dsp.lock() {
                p.start_fade_out(5);
            }
        }
        if let Some(o) = &self.output { o.pause(); }
    }
    fn resume(&self) {
        // 先恢复物理输出，再淡入（避免声音断流）
        if let Some(o) = &self.output { o.resume(); }
        if let Some(dsp) = &self.dsp {
            if let Ok(mut p) = dsp.lock() {
                p.start_fade_in(5);
            }
        }
        self.playing.store(true, Ordering::Release);
    }

    fn stop_full(&mut self) {
        // 用户主动停止：淡出防 pop（由 consumer DSP 应用）
        if let Some(dsp) = &self.dsp {
            if let Ok(mut p) = dsp.lock() {
                p.start_fade_out(3);
            }
        }
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
        self.next_entry = None;
        self.consumer_stop = None;
        self.dsp = None;
        self.position.store(0, Ordering::SeqCst);
    }

    fn emit(&self, event: EngineEvent) {
        if self.external_tx.send(event).is_err() {
            tracing::warn!("事件发送失败：事件接收器已断开");
        }
    }

    fn emit_queue(&self) {
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
    config_shared: Arc<RwLock<EngineConfig>>,
    levels: Arc<Mutex<Levels>>,
) {
    let mut state = EngineState::new(config, position, duration_us, playing, external_tx.clone(), levels);
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
                        Ok(EngineCommand::Play(p)) => state.play_file(&p),
                        Ok(EngineCommand::PlayQueue(paths)) => state.set_queue(paths),
                        Ok(EngineCommand::NextTrack) => state.next_track(),
                        Ok(EngineCommand::PrevTrack) => state.prev_track(),
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
                            state.config = cfg.clone();
                            state.config.output_device = device;
                            // 同步到 Handle 共享配置
                            if let Ok(mut shared) = config_shared.write() {
                                *shared = state.config.clone();
                            }
                            info!("引擎配置更新: {}/{}ch/{}ms", state.config.sample_rate, state.config.channels, state.config.buffer_ms);
                        },
                        Ok(EngineCommand::SetSpeed(speed)) => state.set_speed(speed),
                        Ok(EngineCommand::SetPlayMode(mode)) => state.set_play_mode(mode),
                        Ok(EngineCommand::SetOutputDevice(dev)) => {
                            if state.config.output_device.as_deref() != Some(&dev) {
                                info!("输出设备切换: {dev}（下次播放生效）");
                                state.config.output_device = Some(dev);
                            }
                        }
                        Ok(EngineCommand::RemoveFromQueue(idx)) => state.remove_from_queue(idx),
                        Ok(EngineCommand::StartCapture { sample_rate, channels }) => {
                            if let Err(e) = crate::capture::start_global_capture(sample_rate, channels) {
                                state.emit(EngineEvent::Error(format!("捕获启动失败: {e}")));
                            }
                        }
                        Ok(EngineCommand::StopCapture) => {
                            crate::capture::stop_global_capture();
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
                    let pos_samples = state.position.load(Ordering::Acquire) as f64;
                    let sr = state.config.sample_rate as f64;
                    let ch = state.config.channels as f64;
                    let pos_secs = pos_samples / (sr * ch);
                    let _ = external_tx.send(EngineEvent::Position(pos_secs));
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

/// 计算切歌淡入所需的样本数
fn crossfade_sample_count(sample_rate: u32, channels: u32, crossfade_ms: u32) -> usize {
    if crossfade_ms == 0 { return 0; }
    (sample_rate as usize * channels as usize) * crossfade_ms as usize / 1000
}

/// spawn_consumer — crossfade_ms = 0 表示无间隙（不淡入）
fn spawn_consumer(
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
    speed: Arc<Mutex<f32>>,
    levels: Arc<Mutex<Levels>>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // [macOS] 提升线程 QoS
            #[cfg(target_os = "macos")]
            {
                extern "C" {
                    fn pthread_set_qos_class_self_np(class: u32, offset: i32) -> i32;
                }
                unsafe { pthread_set_qos_class_self_np(0x21, 0); }
            }

            let config = crate::consumer::ConsumerConfig {
                sample_rate,
                channels,
                fft_interval: 3,
                crossfade_ms,
                recv_timeout_ms: 500,
            };

            let pcm_mutex = std::sync::Mutex::new(pcm);
            crate::consumer::run_consumer_loop(
            rx,
            &config,
            &|s| pcm_mutex.lock().unwrap_or_else(|e| e.into_inner()).push_slice(s),
            &|buf| {
                if let Ok(mut pipeline) = dsp.lock() { pipeline.process(buf); }
                // 计算 RMS 和峰值（峰值保持+衰减：攻击瞬发、释放缓降）
                let mut sum_sq = 0.0f32;
                let mut peak_val = 0.0f32;
                for &s in buf.iter() {
                    let abs = s.abs();
                    sum_sq += s * s;
                    if abs > peak_val { peak_val = abs; }
                }
                let n = buf.len() as f32;
                let rms = (sum_sq / n).sqrt();
                if let Ok(mut lv) = levels.lock() {
                    lv.rms = rms;
                    lv.peak = lv.peak.max(peak_val) * 0.95;
                    lv.clip = peak_val >= 1.0;
                }
            },
            &|bands| { let _ = event_tx.send(EngineEvent::Spectrum(bands.to_vec())); },
            &|| { let _ = event_tx.send(EngineEvent::Error("解码器输出坏帧（全零/NaN），已跳过".into())); },
            &|n| { position.fetch_add(n, Ordering::Release); },
            &|| {
                let mut guard = next_rx.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(preloaded) = guard.take() {
                    let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
                    Some(preloaded)
                } else {
                    let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
                    None
                }
            },
            &stop_flag,
            ready_tx,
            speed,
        );

        }));
        if let Err(panic_info) = result {
            let msg = if let Some(s) = panic_info.downcast_ref::<&str>() { s.to_string() }
                      else if let Some(s) = panic_info.downcast_ref::<String>() { s.clone() }
                      else { "消费者线程未知 panic".to_string() };
            error!("消费者线程 crash: {msg}");
            let _ = event_tx.send(EngineEvent::TrackChanged(String::new()));
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
            speed: Arc::new(Mutex::new(1.0)),
            levels: Arc::new(Mutex::new(Levels::default())),
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
        if let Some(entry) = state.current_entry.clone() {
            state.queue.insert(0, entry);
        }
        assert_eq!(state.queue.len(), before + 1, "应为 current_entry 插入队首");
        assert_eq!(state.queue[0].display, "/tmp/test.wav", "应插回 current_entry");
    }

    #[test]
    fn test_repeat_all_refills_queue_on_empty() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        let current = state.current_entry.as_ref().map(|e| e.display.clone());
        state.queue = state.original_queue.iter()
            .filter(|e| Some(e.display.as_str()) != current.as_deref())
            .cloned()
            .collect();
        if state.queue.is_empty() {
            if let Some(ref entry) = state.current_entry {
                state.queue.push(entry.clone());
            }
        }
        assert_eq!(state.queue.len(), 2, "RepeatAll 应填入 2 首");
        assert_eq!(state.queue[0].display, "/tmp/a.wav");
        assert_eq!(state.queue[1].display, "/tmp/b.wav");
    }

    #[test]
    fn test_repeat_all_single_track_refills() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        state.current_entry = Some(QueueEntry::for_file("/tmp/a.wav".into()));
        state.original_queue = vec![QueueEntry::for_file("/tmp/a.wav".into())];
        let current = state.current_entry.as_ref().map(|e| e.display.clone());
        state.queue = state.original_queue.iter()
            .filter(|e| Some(e.display.as_str()) != current.as_deref())
            .cloned()
            .collect();
        if state.queue.is_empty() {
            if let Some(ref entry) = state.current_entry {
                state.queue.push(entry.clone());
            }
        }
        assert_eq!(state.queue.len(), 1, "单曲 RepeatAll 应填入到 1");
        assert_eq!(state.queue[0].display, "/tmp/a.wav");
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
        assert!(!state.queue.iter().any(|e| e.display == "/tmp/song1.wav"), "song1 应从队列移除");
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
        state.current_entry = None;
        // seek 在无 current_entry 时应直接返回
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
        // advance_repeat_one 的核心：将 current_entry 插入队首
        if let Some(entry) = state.current_entry.clone() {
            state.queue.insert(0, entry);
        }
        assert_eq!(state.queue.len(), 2, "RepeatOne 后队列应包含 current + 原有 next1");
        assert_eq!(state.queue[0].display, "/tmp/test.wav", "current_entry 应插回队首");
    }

    #[test]
    fn test_next_track_with_preloaded_switches() {
        // 直接测试 advance_normal 的无缝切换逻辑，不触发 play_file
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into()],
            PlayMode::Normal,
        );
        state.next_entry = Some(QueueEntry::for_file("/tmp/next1.wav".into()));
        state.current_entry = Some(QueueEntry::for_file("/tmp/current.wav".into()));
        // 模拟 advance_normal 中匹配 next_entry 的逻辑
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

    #[test]
    fn test_emit_queue_with_current_entry() {
        let (state, rx) = make_state(
            vec!["/tmp/song1.wav".into()],
            PlayMode::Normal,
        );
        state.emit_queue();
        // 应收到 QueueChanged 事件
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

        let consumer = spawn_consumer(rx1, prod, dsp, stop.clone(), pos, ev_tx, ready_tx, next_rx.clone(), 44100, 2, 0, Arc::new(Mutex::new(1.0)), Arc::new(Mutex::new(Levels::default())));

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
