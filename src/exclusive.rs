//! 独占模式支持
//!
//! - macOS: Hog Mode（通过 CoreAudio AudioObjectSetPropertyData）
//! - Windows: WASAPI Exclusive（预留，cpal 支持有限）
//! - 其他平台: 无操作

use tracing::{info, warn};

/// macOS: 获取 Hog Mode（独占音频设备）
///
/// 设置后其他应用无法使用该设备，直到本进程释放或退出。
#[cfg(target_os = "macos")]
pub fn acquire_exclusive_mode() -> bool {
    use std::os::raw::c_void;

    type AudioDeviceID = u32;
    type OSStatus = i32;

    #[repr(C)]
    struct AudioObjectPropertyAddress {
        selector: u32,
        scope: u32,
        element: u32,
    }

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

    // kAudioHardwarePropertyDefaultOutputDevice = 'dOut'
    // kAudioHardwarePropertyHogModeOwner = 'oHog' (不是标准 selector，用 'oHog')
    const K_AUDIO_HARDWARE_DEFAULT_OUTPUT: u32 = 0x644F7574; // 'dOut'
    const K_AUDIO_HARDWARE_HOG_MODE: u32 = 0x6F486F67; // 'oHog'
    const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: u32 = 0x676C6F62; // 'glob'

    unsafe {
        // 获取默认输出设备 ID
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
        if status != 0 {
            warn!("Hog Mode: 获取默认输出设备失败 (OSStatus={status})");
            return false;
        }

        // 设置 Hog Mode owner 为当前进程
        let pid = std::process::id() as i32;
        let hog_addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_HOG_MODE,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: 0,
        };
        let status = AudioObjectSetPropertyData(
            device_id,
            &hog_addr,
            0,
            std::ptr::null(),
            std::mem::size_of::<i32>() as u32,
            &pid as *const _ as *const c_void,
        );
        if status == 0 {
            info!("Hog Mode 已获取 (device_id={device_id}, pid={pid})");
            true
        } else {
            warn!("Hog Mode 获取失败 (OSStatus={status})，设备可能被其他应用占用");
            false
        }
    }
}

/// macOS: 释放 Hog Mode
#[cfg(target_os = "macos")]
pub fn release_exclusive_mode() {
    use std::os::raw::c_void;

    type AudioDeviceID = u32;
    type OSStatus = i32;

    #[repr(C)]
    struct AudioObjectPropertyAddress {
        selector: u32,
        scope: u32,
        element: u32,
    }

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

    const K_AUDIO_HARDWARE_DEFAULT_OUTPUT: u32 = 0x644F7574;
    const K_AUDIO_HARDWARE_HOG_MODE: u32 = 0x6F486F67;
    const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: u32 = 0x676C6F62;

    unsafe {
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_DEFAULT_OUTPUT,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: 0,
        };
        let mut device_id: AudioDeviceID = 0;
        let mut size: u32 = std::mem::size_of::<AudioDeviceID>() as u32;
        let status = AudioObjectGetPropertyData(
            1,
            &addr,
            0,
            std::ptr::null(),
            &mut size,
            &mut device_id as *mut _ as *mut c_void,
        );
        if status != 0 { return; }

        // 设置 owner 为 -1 释放 Hog Mode
        let release_pid: i32 = -1;
        let hog_addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_HOG_MODE,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: 0,
        };
        AudioObjectSetPropertyData(
            device_id,
            &hog_addr,
            0,
            std::ptr::null(),
            std::mem::size_of::<i32>() as u32,
            &release_pid as *const _ as *const c_void,
        );
        info!("Hog Mode 已释放");
    }
}

/// 非 macOS 平台：独占模式暂不支持，返回 false
#[cfg(not(target_os = "macos"))]
pub fn acquire_exclusive_mode() -> bool {
    // Windows WASAPI Exclusive 需要直接 FFI 调用 IAudioClient::Initialize
    // 当前 cpal 不支持，预留接口
    warn!("当前平台暂不支持独占模式");
    false
}

/// 非 macOS 平台：释放独占模式（无操作）
#[cfg(not(target_os = "macos"))]
pub fn release_exclusive_mode() {
    // 无操作
}
