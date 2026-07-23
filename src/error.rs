//! 统一错误类型
//!
//! 所有引擎内部错误统一为 `EngineError`，替代散落的 `String` 错误消息。

use std::fmt;

/// 引擎错误类型
#[derive(Debug, Clone, PartialEq)]
pub enum EngineError {
    /// 文件不存在
    FileNotFound(String),
    /// 解码失败
    DecodeFailed(String),
    /// 打开音频输出设备失败
    OutputOpenFailed(String),
    /// 音频设备丢失（拔出/断开）
    DeviceLost,
    /// 当前状态不允许该操作
    InvalidState(String),
    /// 无效参数
    InvalidParam(String),
    /// 独占模式获取失败
    ExclusiveModeFailed(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EngineError::FileNotFound(p) => write!(f, "文件不存在: {p}"),
            EngineError::DecodeFailed(msg) => write!(f, "解码失败: {msg}"),
            EngineError::OutputOpenFailed(msg) => write!(f, "打开音频输出失败: {msg}"),
            EngineError::DeviceLost => write!(f, "音频设备丢失"),
            EngineError::InvalidState(msg) => write!(f, "状态错误: {msg}"),
            EngineError::InvalidParam(msg) => write!(f, "参数错误: {msg}"),
            EngineError::ExclusiveModeFailed(msg) => write!(f, "独占模式失败: {msg}"),
        }
    }
}

impl std::error::Error for EngineError {}

impl From<EngineError> for String {
    fn from(e: EngineError) -> String {
        e.to_string()
    }
}
