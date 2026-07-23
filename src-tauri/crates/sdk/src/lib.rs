//! 音乐播放器 SDK
//!
//! 播放器 UI 层只通过此 crate 与音频引擎交互，不直接依赖 audio-core。

/// 引擎控制
pub use audio_core::{EngineConfig, EngineEvent, EngineHandle, Levels, PlayMode, TARGET_CHANNELS, TARGET_SAMPLE_RATE};
/// 统一错误类型
pub use audio_core::EngineError;

/// 音频输出设备
pub mod output {
    pub use audio_core::output::list_device_names;
}

/// 独占模式（macOS Hog Mode / Windows WASAPI Exclusive）
pub mod exclusive {
    pub use audio_core::exclusive::{acquire_exclusive_mode, release_exclusive_mode};
}

/// DSP 管线
pub mod dsp {
    pub use audio_core::dsp::{default_peq_bands, preset_bands, PeqBand, PresetName};
}

/// 音频分析
pub use audio_core::analysis::{analyze_file, analyze_from_samples, AnalysisResult};

/// 音频输入捕获
pub use audio_core::capture::{is_capturing, start_global_capture, stop_global_capture};

/// 曲库管理
pub mod library;
