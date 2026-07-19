pub mod analysis;
pub mod decoder;
pub mod dsd;
pub mod dsp;

#[cfg(feature = "cpal-backend")]
pub mod engine;
#[cfg(feature = "cpal-backend")]
pub mod output;

/// 目标输出格式（默认值，可通过 EngineConfig 覆盖）
pub const TARGET_SAMPLE_RATE: u32 = 44100;
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
}

impl Default for EngineConfig {
    fn default() -> Self {
        EngineConfig {
            sample_rate: TARGET_SAMPLE_RATE,
            channels: TARGET_CHANNELS,
            buffer_ms: 280,
            crossfade_ms: 0,
            output_device: None,
        }
    }
}

#[cfg(feature = "cpal-backend")]
pub use engine::{EngineEvent, EngineHandle, PlayMode};
pub use decoder::Metadata;
pub use dsp::{default_peq_bands, preset_bands, DspPipeline, PeqBand, PresetName};
