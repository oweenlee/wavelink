use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::sync::Mutex;

use sdk::dsp::PeqBand;
use sdk::library::LibraryDb;
use sdk::output::DeviceMonitor;
use sdk::stream::StreamHandle;
use sdk::{EngineHandle, PlayMode};

use crate::media_bridge::MediaBridge;
use crate::nas::NasManager;

/// 全局状态
pub struct AppState {
    pub engine: EngineHandle,
    pub library: Mutex<LibraryDb>,
    pub db_path: PathBuf,
    pub peq_bands: Mutex<Vec<PeqBand>>,
    pub play_mode: Mutex<PlayMode>,
    pub replaygain_enabled: Mutex<bool>,
    pub base_volume: Mutex<f64>,
    pub current_track: Mutex<Option<String>>,
    pub media_bridge: MediaBridge,
    pub nas_manager: NasManager,
    /// 设备热插拔监视器
    pub device_monitor: Mutex<Option<DeviceMonitor>>,
    /// 监视器线程停止标志
    pub device_monitor_stop: Arc<AtomicBool>,
    /// 流式播放写入句柄
    pub stream_handle: Mutex<Option<StreamHandle>>,
    /// 当前流式播放源（url, name, format_hint）：seek 重启 / 系统媒体信息用
    pub stream_source: Mutex<Option<(String, String, Option<String>)>>,
}
