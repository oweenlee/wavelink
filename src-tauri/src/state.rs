use std::path::PathBuf;
use std::sync::Mutex;

use sdk::dsp::PeqBand;
use sdk::library::LibraryDb;
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
}
