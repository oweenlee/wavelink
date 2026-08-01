#![warn(missing_docs)]
// DSP / 音频数值代码中，索引循环、多参数函数与复杂类型是清晰且惯用的写法，
// 这几个 clippy 风格 lint 在本场景下意义不大，统一放行。
#![allow(
    clippy::needless_range_loop,
    clippy::too_many_arguments,
    clippy::type_complexity
)]

//! 纯 Rust 跨端音频引擎：解码 / DSP 管线 / 频谱分析 / BPM 调性检测。
//! 被 wavelink-app（桌面端）和 wavelink_mobile（移动端）通过 path 依赖引用。

/// 音频分析（BPM 检测 / 调性识别 / 能量计算）
pub mod analysis;
/// 音频输入捕获抽象层
pub mod capture;
/// 平台无关的解码→DSP→ringbuf 循环（PC 和 Mobile 共享）
pub mod consumer;
/// 音频文件解码（Symphonia 流式解码 + WavPack + DSD）
pub mod decoder;
/// DSD（DSF/DFF）格式直解为 PCM
pub mod dsd;
/// CUE 分轨解析
pub mod cue;
/// DSP 管线：参数均衡器 / 串音补偿 / 立体声展宽 / 限幅 / 抖动
pub mod dsp;
/// 统一错误类型
pub mod error;
/// 独占模式（macOS Hog Mode / Windows WASAPI Exclusive）
pub mod exclusive;

/// 音频引擎（桌面端 cpal / 移动端 HeadlessOutput）
pub mod engine;
/// 音频输出抽象（cpal / HeadlessOutput）
pub mod output;
/// 流式音频数据源（网络流媒体解码用，平台层写入字节流）
pub mod stream;
/// 播放列表解析（M3U / M3U8 / PLS）
pub mod playlist;

/// 目标输出采样率（默认 44100 Hz），可通过 EngineConfig 覆盖
pub const TARGET_SAMPLE_RATE: u32 = 44100;
/// 目标输出声道数（默认 2 = 立体声）
pub const TARGET_CHANNELS: u32 = 2;

/// 引擎配置
#[derive(Clone, Debug)]
pub struct EngineConfig {
    /// 输出采样率，默认 44100
    pub sample_rate: u32,
    /// 输出声道数，默认 2
    pub channels: u32,
    /// ringbuf 缓冲时长（毫秒），默认 280
    pub buffer_ms: u32,
    /// 切歌淡入时长（毫秒），0 = 真·无间隙播放，默认 0
    pub crossfade_ms: u32,
    /// 输出设备名称，None = 使用系统默认设备
    pub output_device: Option<String>,
    /// 是否自动匹配文件采样率到输出设备（HiFi 场景建议开启）
    pub auto_sample_rate: bool,
    /// 是否请求独占模式（WASAPI Exclusive / macOS Hog Mode）
    pub exclusive_mode: bool,
    /// Bit-perfect 模式：绕过所有 DSP，输出采样率/位深精确匹配源文件
    pub bit_perfect: bool,
}

impl Default for EngineConfig {
    fn default() -> Self {
        EngineConfig {
            sample_rate: TARGET_SAMPLE_RATE,
            channels: TARGET_CHANNELS,
            buffer_ms: 280,
            crossfade_ms: 0,
            output_device: None,
            auto_sample_rate: false,
            exclusive_mode: false,
            bit_perfect: false,
        }
    }
}

/// 引擎事件 / 引擎句柄 / 播放模式 / 电平数据
#[doc(inline)]
pub use engine::{EngineEvent, EngineHandle, Levels, PlayMode};
/// 统一错误类型
#[doc(inline)]
pub use error::EngineError;
