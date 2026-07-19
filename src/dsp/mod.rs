//! DSP 管线模块
//!
//! 专业音质 DSP 链（参考计划书定位，对标 Roon/CamillaDSP 级别）：
//!   DC offset HPF → Pre-amp → ReplayGain → Resampler(后续) →
//!   FIR 卷积 EQ → IIR PEQ → Crossfeed → 真峰值限幅 → 音量 → TPDF 抖动
//!
//! 本模块自研核心滤波器（纯 Rust、零额外重依赖），便于单元测试验证
//! （计划书强调：DSP 正确性必须靠自动化测试，不能靠人工试听）。

pub mod biquad;
pub mod convolver;
pub mod crossfeed;
pub mod dither;
pub mod limiter;
pub mod pipeline;
pub mod widener;

pub use pipeline::{default_peq_bands, preset_bands, DspPipeline, PeqBand, PresetName};
