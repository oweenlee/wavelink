//! 独占模式支持
//!
//! - macOS: Hog Mode（通过 CoreAudio AudioObjectSetPropertyData）
//! - Windows: WASAPI Exclusive（预留，cpal 支持有限）
//! - 其他平台: 无操作
//!
//! 独占始终作用于「实际选中的输出设备」：传入设备名则锁定该设备，
//! 传 `None` 或设备不存在时回退到系统默认输出设备。

// info 仅在 macOS / Windows 路径使用；其他平台只用 warn。
// 按平台限定导入，避免交叉编译时的 unused import 警告。
#[cfg(any(target_os = "macos", target_os = "windows"))]
use tracing::info;
use tracing::warn;

// ───────────────────────── macOS (CoreAudio Hog Mode) ─────────────────────────

#[cfg(target_os = "macos")]
use std::os::raw::c_void;

#[cfg(target_os = "macos")]
type AudioDeviceID = u32;
#[cfg(target_os = "macos")]
type OSStatus = i32;

#[cfg(target_os = "macos")]
#[repr(C)]
struct AudioObjectPropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

#[cfg(target_os = "macos")]
extern "C" {
    fn AudioObjectGetPropertyData(
        object_id: AudioDeviceID,
        address: *const AudioObjectPropertyAddress,
        qualifier_data_size: u32,
        qualifier_data: *const c_void,
        data_size: *mut u32,
        data: *mut c_void,
    ) -> OSStatus;

    fn AudioObjectSetPropertyData(
        object_id: AudioDeviceID,
        address: *const AudioObjectPropertyAddress,
        qualifier_data_size: u32,
        qualifier_data: *const c_void,
        data_size: u32,
        data: *const c_void,
    ) -> OSStatus;
}

#[cfg(target_os = "macos")]
const K_AUDIO_HARDWARE_DEFAULT_OUTPUT: u32 = 0x644F7574; // 'dOut'
#[cfg(target_os = "macos")]
const K_AUDIO_DEVICE_PROPERTY_HOG_MODE_OWNER: u32 = 0x694F776E; // 'iOwn'
#[cfg(target_os = "macos")]
const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: u32 = 0x676C6F62; // 'glob'

/// 获取系统默认输出设备 ID
#[cfg(target_os = "macos")]
fn default_output_id() -> Option<AudioDeviceID> {
    unsafe {
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_DEFAULT_OUTPUT,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: 0, // kAudioObjectPropertyElementMain
        };
        let mut device_id: AudioDeviceID = 0;
        let mut size: u32 = std::mem::size_of::<AudioDeviceID>() as u32;
        let status = AudioObjectGetPropertyData(
            1, // kAudioObjectSystemObject
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            &mut device_id as *mut _ as *mut c_void,
        );
        if status == 0 && device_id != 0 {
            Some(device_id)
        } else {
            warn!("Hog Mode: 获取默认输出设备失败 (OSStatus={status})");
            None
        }
    }
}

/// 按设备名解析目标 AudioDeviceID。
///
/// - `None` → 系统默认输出设备
/// - `Some(name)` → 名称匹配的设备；找不到时告警并回退默认输出
#[cfg(target_os = "macos")]
fn resolve_device_id(device_name: Option<&str>) -> Option<AudioDeviceID> {
    let name = match device_name {
        None => return default_output_id(),
        Some(n) => n,
    };
    // OutputDeviceInfo.id 即 AudioDeviceID 的字符串形式，复用已有枚举保证与 UI 一致
    let found = crate::output::enumerate_devices()
        .into_iter()
        .find(|d| d.name == name)
        .and_then(|d| d.id.parse::<AudioDeviceID>().ok());
    found.or_else(|| {
        warn!("Hog Mode: 未找到设备 \"{name}\"，回退到系统默认输出");
        default_output_id()
    })
}

/// 设置指定设备的 Hog Mode owner（owner = 进程 PID 获取，-1 释放）
#[cfg(target_os = "macos")]
fn set_hog_owner(device_id: AudioDeviceID, owner: i32) -> bool {
    unsafe {
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_DEVICE_PROPERTY_HOG_MODE_OWNER,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: 0,
        };
        let status = AudioObjectSetPropertyData(
            device_id,
            &addr,
            0,
            std::ptr::null(),
            std::mem::size_of::<i32>() as u32,
            &owner as *const _ as *const c_void,
        );
        status == 0
    }
}

/// macOS: 获取 Hog Mode（独占指定/默认音频设备）
///
/// 设置后其他应用无法使用该设备，直到本进程释放或退出。
#[cfg(target_os = "macos")]
pub fn acquire_exclusive_mode(device_name: Option<&str>) -> bool {
    let device_id = match resolve_device_id(device_name) {
        Some(id) => id,
        None => {
            warn!("Hog Mode: 无法解析输出设备，放弃独占");
            return false;
        }
    };
    let pid = std::process::id() as i32;
    if set_hog_owner(device_id, pid) {
        info!("Hog Mode 已获取 (device_id={device_id}, device={device_name:?}, pid={pid})");
        true
    } else {
        warn!("Hog Mode 获取失败 (device_id={device_id})，设备可能被其他应用占用");
        false
    }
}

/// macOS: 释放 Hog Mode
#[cfg(target_os = "macos")]
pub fn release_exclusive_mode(device_name: Option<&str>) {
    if let Some(device_id) = resolve_device_id(device_name) {
        set_hog_owner(device_id, -1);
        info!("Hog Mode 已释放 (device_id={device_id})");
    }
}

// ───────────────────────── Windows (WASAPI Exclusive) ─────────────────────────

/// Windows: 独占模式由 WASAPI 后端在打开音频流时按流获取
/// （IAudioClient::Initialize + AUDCLNT_SHAREMODE_EXCLUSIVE，失败自动降级共享）。
/// 此处仅报告能力，不做 COM 初始化——COM 生命周期由后端自行管理，避免引用计数失衡。
#[cfg(target_os = "windows")]
pub fn acquire_exclusive_mode(_device_name: Option<&str>) -> bool {
    // 用 cfg!() 而非 #[cfg] 块：保证 info/warn 在两种 feature 下都被引用
    // （死分支仅在优化期消除，不会触发 unused import）。
    if cfg!(feature = "wasapi-backend") {
        info!("WASAPI 独占模式将由音频后端按流获取");
        true
    } else {
        warn!("wasapi-backend 未启用，独占模式不可用");
        false
    }
}

/// Windows: 独占随音频流关闭自动释放，此处无操作
#[cfg(target_os = "windows")]
pub fn release_exclusive_mode(_device_name: Option<&str>) {
}

// ───────────────────────── 其他平台 ─────────────────────────

/// 其他平台：独占模式暂不支持
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn acquire_exclusive_mode(_device_name: Option<&str>) -> bool {
    warn!("当前平台暂不支持独占模式");
    false
}

/// 其他平台：释放独占模式（无操作）
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn release_exclusive_mode(_device_name: Option<&str>) {
}
