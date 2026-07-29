//! EngineHandle — 对外的线程安全句柄

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{bounded, unbounded, Receiver, Sender};
use parking_lot::Mutex;

use super::command::{EngineCommand, EngineEvent, Levels, PlayMode};
use super::worker::run_engine;
use crate::dsp::PeqBand;
use crate::error::EngineError;
use crate::capture::CaptureInner;
use crate::output::AudioOutputInner;
use crate::stream::StreamHandle;
use crate::EngineConfig;

/// 对外的句柄（Send + Sync）
#[derive(Clone)]
pub struct EngineHandle {
    /// 命令发送端
    pub(crate) tx: Sender<EngineCommand>,
    /// 当前播放位置（样本数），外部可读
    pub(crate) position: Arc<AtomicU64>,
    /// 曲目时长（微秒）
    pub(crate) duration_us: Arc<AtomicU64>,
    /// 播放状态（是否正在播放）
    pub(crate) playing: Arc<AtomicBool>,
    /// 引擎配置（与引擎线程共享，SetConfig 时同步更新）
    pub(crate) config: Arc<RwLock<EngineConfig>>,
    /// 实时电平
    pub(crate) levels: Arc<Mutex<Levels>>,
    /// 共享输出内部状态（替代全局 static，供 FFI 层读取音频数据）
    pub output_inner: Arc<RwLock<Option<Arc<AudioOutputInner>>>>,
    /// 实际输出采样率（与 EngineState.output_sample_rate 同步）
    pub(crate) output_sample_rate: Arc<AtomicU32>,
    /// 捕获缓冲（替代全局 CAPTURE_INNER，供 FFI 层读取捕获数据）
    #[allow(dead_code)] // 仅通过 FFI 层指针访问
    pub(crate) capture_inner: Arc<RwLock<Option<Arc<CaptureInner>>>>,
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
        let output_inner: Arc<RwLock<Option<Arc<AudioOutputInner>>>> = Arc::new(RwLock::new(None));
        let output_sample_rate = Arc::new(AtomicU32::new(config.sample_rate));
        let capture_inner: Arc<RwLock<Option<Arc<CaptureInner>>>> = Arc::new(RwLock::new(None));
        let pos_clone = Arc::clone(&position);
        let dur_clone = Arc::clone(&duration_us);
        let playing_clone = Arc::clone(&playing);
        let levels_clone = Arc::clone(&levels);
        let output_inner_clone = Arc::clone(&output_inner);
        let output_sr_clone = Arc::clone(&output_sample_rate);
        let capture_inner_clone = Arc::clone(&capture_inner);
        let config_shared = Arc::new(RwLock::new(config.clone()));
        let config_for_engine = Arc::clone(&config_shared);
        thread::spawn(move || run_engine(cmd_rx, event_tx, pos_clone, dur_clone, playing_clone, config, config_for_engine, levels_clone, output_inner_clone, output_sr_clone, capture_inner_clone));
        (EngineHandle { tx, position, duration_us, playing, config: config_shared, levels, output_inner, output_sample_rate, capture_inner }, event_rx)
    }

    /// 获取当前音频电平（RMS / 峰值 / 削波标志）
    pub fn levels(&self) -> Levels {
        self.levels.lock().clone()
    }

    /// 开始播放指定路径的音频文件（异步，fire-and-forget）
    pub fn play(&self, path: String) { let _ = self.tx.send(EngineCommand::Play(path, None)); }
    /// 同步播放（等待引擎确认启动成功）
    pub fn play_sync(&self, path: String) -> Result<(), EngineError> {
        let (ack_tx, ack_rx) = bounded(1);
        let _ = self.tx.send(EngineCommand::Play(path, Some(ack_tx)));
        ack_rx.recv_timeout(Duration::from_secs(5))
            .unwrap_or(Err(EngineError::InvalidState("应答超时".into())))
    }
    /// 开始流式播放（网络流媒体用），返回 StreamHandle 供写入数据
    pub fn play_stream(&self, format_hint: Option<String>, content_length: Option<u64>) -> Result<StreamHandle, EngineError> {
        self.play_stream_impl(format_hint, content_length, Duration::from_secs(5))
    }
    /// 同步流式播放（等待引擎确认启动成功），返回 StreamHandle
    pub fn play_stream_sync(&self, format_hint: Option<String>, content_length: Option<u64>) -> Result<StreamHandle, EngineError> {
        self.play_stream_impl(format_hint, content_length, Duration::from_secs(15))
    }
    /// 流式播放通用实现
    fn play_stream_impl(&self, format_hint: Option<String>, content_length: Option<u64>, timeout: Duration) -> Result<StreamHandle, EngineError> {
        let (ack_tx, ack_rx) = bounded(1);
        let (handle_tx, handle_rx) = bounded(1);
        let shared_tx = std::sync::Arc::new(handle_tx);
        let _ = self.tx.send(EngineCommand::PlayStream {
            format_hint, content_length,
            ack: Some(ack_tx),
            stream_handle_out: Some(shared_tx),
        });
        ack_rx.recv_timeout(timeout)
            .unwrap_or(Err(EngineError::InvalidState("引擎无响应".into())))?;
        handle_rx.recv_timeout(Duration::from_secs(1))
            .map_err(|_| EngineError::InvalidState("引擎未返回流句柄".into()))
    }
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
    /// 跳转到指定位置（秒，异步）
    pub fn seek(&self, pos: f64) { let _ = self.tx.send(EngineCommand::Seek(pos, None)); }
    /// 同步跳转（等待引擎确认 seek 完成）
    pub fn seek_sync(&self, pos: f64) -> Result<(), EngineError> {
        let (ack_tx, ack_rx) = bounded(1);
        let _ = self.tx.send(EngineCommand::Seek(pos, Some(ack_tx)));
        ack_rx.recv_timeout(Duration::from_secs(5))
            .unwrap_or(Err(EngineError::InvalidState("应答超时".into())))
    }
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
    /// 设置跨馈
    pub fn set_crossfeed(&self, enabled: bool) {
        let _ = self.tx.send(EngineCommand::SetCrossfeed(enabled));
    }
    /// 设置音量（0.0 ~ 2.0）
    pub fn set_volume(&self, vol: f32) { let _ = self.tx.send(EngineCommand::SetVolume(vol)); }
    /// 设置 ReplayGain 增益（dB），作为 Pre-amp 在 DSP 管线 HPF 后、EQ 前应用
    pub fn set_replaygain_gain_db(&self, gain_db: f32) { let _ = self.tx.send(EngineCommand::SetReplaygainGain(gain_db)); }
    /// 设置 ReplayGain 真峰值（0~1），增益将被限制为不超过 0dBFS。None = 不限制
    pub fn set_replaygain_peak(&self, peak: Option<f32>) { let _ = self.tx.send(EngineCommand::SetReplaygainPeak(peak)); }
    /// 更新引擎配置（采样率/声道/缓冲），下次播放时生效
    pub fn set_config(&self, config: EngineConfig) {
        let _ = self.tx.send(EngineCommand::SetConfig(config));
    }
    /// 设置播放模式（普通 / 单曲循环 / 随机）
    pub fn set_play_mode(&self, mode: PlayMode) { let _ = self.tx.send(EngineCommand::SetPlayMode(mode)); }
    /// 从队列中移除指定索引的曲目
    pub fn remove_from_queue(&self, index: usize) { let _ = self.tx.send(EngineCommand::RemoveFromQueue(index)); }
    /// 设置输出设备名称（None = 系统默认），下次播放时生效
    pub fn set_output_device(&self, name: String) {
        let _ = self.tx.send(EngineCommand::SetOutputDevice(name, None));
    }
    /// 同步设置输出设备（等待引擎确认）
    pub fn set_output_device_sync(&self, name: String) -> Result<(), EngineError> {
        let (ack_tx, ack_rx) = bounded(1);
        let _ = self.tx.send(EngineCommand::SetOutputDevice(name, Some(ack_tx)));
        ack_rx.recv_timeout(Duration::from_secs(5))
            .unwrap_or(Err(EngineError::InvalidState("应答超时".into())))
    }
    /// 获取当前播放位置（秒）
    pub fn position_secs(&self) -> f64 {
        let samples = self.position.load(Ordering::Acquire);
        let sr = self.output_sample_rate.load(Ordering::Acquire) as f64;
        let ch = self.config.read().unwrap_or_else(|e| e.into_inner()).channels as f64;
        if sr > 0.0 && ch > 0.0 { samples as f64 / (sr * ch) } else { 0.0 }
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
    /// 启用/禁用 ATH 噪声整形
    pub fn set_noise_shaping(&self, enabled: bool) {
        let _ = self.tx.send(EngineCommand::SetNoiseShaping(enabled));
    }
    /// 动态调整输出缓冲时长（毫秒），实时生效。仅在 Oboe 后端受支持。
    pub fn set_buffer_ms(&self, ms: u32) {
        let _ = self.tx.send(EngineCommand::SetBufferMs(ms));
    }
    /// 查询 underrun 计数
    pub fn underrun_count(&self) -> u64 {
        let (tx, rx) = bounded(1);
        let _ = self.tx.send(EngineCommand::QueryUnderrunCount(tx));
        rx.recv_timeout(Duration::from_secs(1)).unwrap_or(0)
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

    /// 从引擎的 ringbuf 读取交错 PCM 样本（替代全局 read_output_samples）。
    /// 返回实际读取的样本数；若输出未初始化返回 0。
    pub fn read_samples(&self, buf: &mut [f32]) -> usize {
        use ringbuf::traits::Consumer;
        self.output_inner.read()
            .ok()
            .and_then(|guard| guard.clone())
            .map(|inner| inner.consumer.lock().pop_slice(buf))
            .unwrap_or(0)
    }
}
