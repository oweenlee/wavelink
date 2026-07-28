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

    const K_AUDIO_HARDWARE_DEFAULT_OUTPUT: u32 = 0x644F7574; // 'dOut'
    const K_AUDIO_DEVICE_PROPERTY_HOG_MODE_OWNER: u32 = 0x694F776E; // 'iOwn'
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
            selector: K_AUDIO_DEVICE_PROPERTY_HOG_MODE_OWNER,
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
    const K_AUDIO_DEVICE_PROPERTY_HOG_MODE_OWNER: u32 = 0x694F776E;
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
            selector: K_AUDIO_DEVICE_PROPERTY_HOG_MODE_OWNER,
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

/// Windows: WASAPI Exclusive 模式初始化 COM
///
/// 注意：实际独占模式获取发生在 IAudioClient::Initialize 中，
/// 此处仅初始化 COM，确保 WASAPI FFI 可以正常工作。
#[cfg(target_os = "windows")]
pub fn acquire_exclusive_mode() -> bool {
    #[cfg(feature = "wasapi-backend")]
    {
        use windows_sys::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
        let hr = unsafe { CoInitializeEx(std::ptr::null_mut(), COINIT_MULTITHREADED) };
        if hr == 0 || hr == 1 {
            info!("WASAPI COM 初始化成功");
            true
        } else {
            warn!("WASAPI COM 初始化失败: HRESULT=0x{hr:08X}");
            false
        }
    }
    #[cfg(not(feature = "wasapi-backend"))]
    {
        warn!("wasapi-backend 未启用，独占模式不可用");
        false
    }
}

/// Windows: 释放 COM
#[cfg(target_os = "windows")]
pub fn release_exclusive_mode() {
    #[cfg(feature = "wasapi-backend")]
    {
        use windows_sys::Win32::System::Com::CoUninitialize;
        unsafe { CoUninitialize(); }
        info!("WASAPI COM 已释放");
    }
}

/// 其他平台：独占模式暂不支持
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn acquire_exclusive_mode() -> bool {
    warn!("当前平台暂不支持独占模式");
    false
}

/// 其他平台：释放独占模式（无操作）
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn release_exclusive_mode() {
}
