//! 设备枚举、输出决策、热插拔监测（FRB 包装层）

use once_cell::sync::OnceCell;
use std::sync::Mutex;

static DEVICE_MONITOR: OnceCell<Mutex<Option<audio_core::output::DeviceMonitor>>> =
    OnceCell::new();

/// 输出设备信息（给 Dart 展示设备列表用）
pub struct DeviceInfoDto {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub is_usb: bool,
}

/// 输出决策结果
pub struct OutputDecisionDto {
    pub device_id: String,
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub exclusive: bool,
    pub need_resample: bool,
    pub reason: String,
}

/// 源音频格式
pub struct SourceFormatDto {
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub channels: u16,
}

/// 列举所有输出设备
pub fn enumerate_devices() -> Vec<DeviceInfoDto> {
    audio_core::output::enumerate_devices()
        .into_iter()
        .map(|d| DeviceInfoDto {
            id: d.id,
            name: d.name,
            is_default: d.is_default,
            is_usb: d.is_usb,
        })
        .collect()
}

/// 输出决策：设备 + 源格式 → 最优输出配置
pub fn decide_output(
    device_id: String,
    source_sr: u32,
    source_bits: u8,
    source_ch: u16,
    source_is_dsd: bool,
    prefer_exclusive: bool,
) -> Option<OutputDecisionDto> {
    let device = audio_core::output::enumerate_devices()
        .into_iter()
        .find(|d| d.id == device_id)?;

    let source = audio_core::output::SourceFormat {
        sample_rate: source_sr,
        bit_depth: source_bits,
        channels: source_ch,
        is_dsd: source_is_dsd,
        dsd_rate: None,
    };

    let decision = audio_core::output::decide_output(&device, &source, prefer_exclusive).ok()?;

    Some(OutputDecisionDto {
        device_id: decision.device_id,
        sample_rate: decision.sample_rate,
        bit_depth: decision.bit_depth,
        exclusive: decision.exclusive,
        need_resample: decision.need_resample,
        reason: decision.reason,
    })
}

/// 启动设备热插拔监测
pub fn device_monitor_start() {
    if DEVICE_MONITOR.get().is_some() {
        return;
    }
    let monitor = audio_core::output::start_device_monitor();
    DEVICE_MONITOR.get_or_init(|| Mutex::new(Some(monitor)));
}

/// 停止设备热插拔监测
pub fn device_monitor_stop() {
    if let Some(mtx) = DEVICE_MONITOR.get() {
        if let Ok(mut g) = mtx.lock() {
            *g = None;
        }
    }
}

/// 轮询设备事件（Dart 侧定期调用，返回后事件即丢弃）
pub fn device_monitor_poll_events() -> Vec<String> {
    let guard = match DEVICE_MONITOR.get().and_then(|mtx| mtx.lock().ok()) {
        Some(g) => g,
        None => return vec![],
    };
    let monitor = match guard.as_ref() {
        Some(m) => m,
        None => return vec![],
    };

    let mut events = Vec::new();
    while let Ok(event) = monitor.receiver().try_recv() {
        let s = match event {
            audio_core::output::DeviceEvent::DeviceAdded(name) => format!("added:{name}"),
            audio_core::output::DeviceEvent::DeviceRemoved(name) => format!("removed:{name}"),
            audio_core::output::DeviceEvent::DefaultDeviceChanged => "default_changed".into(),
        };
        events.push(s);
    }
    events
}
