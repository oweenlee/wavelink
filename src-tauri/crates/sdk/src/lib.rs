//! 音乐播放器 SDK
//!
//! 播放器 UI 层只通过此 crate 与音频引擎交互，不直接依赖 audio-core。

/// 引擎控制
pub use audio_core::{EngineConfig, EngineEvent, EngineHandle, Levels, PlayMode, TARGET_CHANNELS, TARGET_SAMPLE_RATE};
/// 统一错误类型
pub use audio_core::EngineError;
/// 元数据
pub use audio_core::decoder::{Metadata, ReplayGain, read_metadata, read_cover, read_replaygain};
/// 文件探测
pub use audio_core::decoder::{probe_sample_rate, probe_bit_depth};
/// CUE 分轨解析
pub use audio_core::cue::{parse_cue, parse_cue_str, CueSheet, CueFile, CueTrack};
/// 音频分析
pub use audio_core::analysis::{analyze_file, analyze_from_samples, AnalysisResult, mix_to_mono};
pub use audio_core::analysis::bpm::detect_bpm;
pub use audio_core::analysis::key::detect_key;
/// 音频输入捕获
pub use audio_core::capture::{is_capturing, start_global_capture, stop_global_capture};

/// 播放列表解析
pub mod playlist {
    pub use audio_core::playlist::{parse_playlist, export_m3u, export_pls, export_playlist, PlaylistEntry};
}

/// 音频输出设备
pub mod output {
    pub use audio_core::output::{
        list_device_names, enumerate_devices, start_device_monitor,
        DeviceMonitor, DeviceEvent, OutputDeviceInfo, DeviceConfig,
        SampleFormat, OutputDecision, SourceFormat, decide_output,
    };
}

/// 独占模式（macOS Hog Mode / Windows WASAPI Exclusive）
pub mod exclusive {
    pub use audio_core::exclusive::{acquire_exclusive_mode, release_exclusive_mode};
}

/// DSP 管线
pub mod dsp {
    pub use audio_core::dsp::{default_peq_bands, preset_bands, PeqBand, PresetName};
}

/// 流式播放（网络流媒体）
pub mod stream {
    pub use audio_core::stream::{StreamHandle, stream_pair};
}

/// 曲库管理
pub mod library;
