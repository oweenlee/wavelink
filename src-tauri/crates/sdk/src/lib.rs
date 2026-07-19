//! 音乐播放器 SDK
//!
//! 播放器 UI 层只通过此 crate 与音频引擎交互，不直接依赖 audio-core。

/// 引擎控制
pub use audio_core::{EngineConfig, EngineEvent, EngineHandle, PlayMode, TARGET_CHANNELS, TARGET_SAMPLE_RATE};

/// 音频输出设备
pub mod output {
    pub use audio_core::output::list_device_names;
}

/// DSP 管线
pub mod dsp {
    pub use audio_core::dsp::{default_peq_bands, preset_bands, PeqBand, PresetName};
}

/// 音频分析
pub use audio_core::analysis::{analyze_file, analyze_from_samples, AnalysisResult};

/// 曲库管理
pub mod library;
