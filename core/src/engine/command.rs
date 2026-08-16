//! 引擎命令与事件类型定义

use crossbeam_channel::Sender;

use crate::dsp::PeqBand;
use crate::error::EngineError;
use crate::EngineConfig;

/// 命令应答通道类型
pub type CmdAck = Option<Sender<Result<(), EngineError>>>;

/// 频谱分析数据（16 个频段幅值，0.0~1.0 归一化）
pub const SPECTRUM_BANDS: usize = 16;

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

/// 发给引擎线程的命令
pub enum EngineCommand {
    /// 播放单个文件（可选同步确认）
    Play(String, CmdAck),
    /// 从流式数据源播放（网络流媒体，可选同步确认）
    PlayStream {
        /// 格式提示（如 "mp3", "flac", "aac"）
        format_hint: Option<String>,
        /// 内容长度（字节，可选）
        content_length: Option<u64>,
        /// 应答通道
        ack: CmdAck,
        /// 流句柄共享存储（宿主层持有 Arc，引擎线程写入）
        stream_handle_out:
            Option<std::sync::Arc<crossbeam_channel::Sender<crate::stream::StreamHandle>>>,
    },
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
    /// 跳转到指定位置（秒，可选同步确认）
    Seek(f64, CmdAck),
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
    /// 应用 AutoEQ 耳机校正档案（型号名，None = 清除恢复平坦）。
    /// 档案表见 `audio_core::dsp::autoeq::catalog()`。
    SetAutoEq(Option<String>),
    /// 设置 DSD 播放模式（ToPcm / Dop），下次播放生效
    SetDsdMode(crate::DsdMode),
    /// 设置立体声展宽
    SetStereoWidener {
        /// 是否启用展宽
        enabled: bool,
        /// 展宽系数（0=单声道, 1=原始, >1=展宽）
        width: f32,
    },
    /// 设置跨馈
    SetCrossfeed(bool),
    /// 设置音量
    SetVolume(f32),
    /// 设置 ReplayGain 增益（dB）
    SetReplaygainGain(f32),
    /// 设置 ReplayGain 真峰值（用于限制增益不过载），None = 不限制
    SetReplaygainPeak(Option<f32>),
    /// 更新引擎配置，下次播放时生效
    SetConfig(EngineConfig),
    /// 设置播放模式
    SetPlayMode(PlayMode),
    /// 从队列中移除指定索引的曲目
    RemoveFromQueue(usize),
    /// 设置输出设备（下次播放生效，可选同步确认）
    SetOutputDevice(String, CmdAck),
    /// 设置播放速度（0.25 ~ 4.0），1.0 = 正常
    SetSpeed(f32),
    /// 启用/禁用 ATH 噪声整形（替代 TPDF 抖动）
    SetNoiseShaping(bool),
    /// 启用/禁用真峰值限幅
    SetLimiterEnabled(bool),
    /// 启用/禁用抖动（含噪声整形）
    SetDitherEnabled(bool),
    /// 动态调整输出缓冲时长（毫秒），实时生效
    SetBufferMs(u32),
    /// 设置输出采样率（下次播放生效）。
    /// 移动端 bit-perfect 协调：平台层先把设备设到目标速率（iOS AVAudioSession）并读回实际速率，
    /// 再发本命令使引擎输出速率与设备一致；若等于源文件速率则解码器不重采样（bit-perfect）。
    SetOutputSampleRate(u32),
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
    /// DoP 直出状态变更（true = 当前曲目以 DoP 输出，false = PCM）
    DopActive(bool),
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
    fn default() -> Levels {
        Levels {
            rms: 0.0,
            peak: 0.0,
            clip: false,
        }
    }
}
