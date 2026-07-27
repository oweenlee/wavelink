//! 音频引擎模块
//!
//! 对外公开类型：EngineHandle, EngineEvent, EngineCommand, PlayMode, Levels, SPECTRUM_BANDS

mod command;
mod handle;
mod queue;
pub(crate) mod output_setup;
pub(crate) mod recovery;
pub(crate) mod state;
pub(crate) mod thread_priority;
pub(crate) mod worker;

// ── 公开类型 re-export ──
pub use command::{EngineCommand, EngineEvent, Levels, PlayMode, SPECTRUM_BANDS};
pub use handle::EngineHandle;
