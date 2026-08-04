//! macOS CoreAudio 设备枚举
//!
//! 使用 raw FFI 直接调用 CoreAudio 框架，不依赖 coreaudio-sys。
//! 仅 macOS 时编译。

use crate::output::{DeviceConfig, OutputDeviceInfo, SampleFormat};

type AudioDeviceID = u32;
type OSStatus = i32;

#[repr(C)]
struct AudioObjectPropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

#[repr(C)]
struct AudioValueRange {
    minimum: f64,
    maximum: f64,
}

const K_AUDIO_HARDWARE_DEVICES: u32 = 0x6465766D;
const K_AUDIO_HARDWARE_DEFAULT_OUTPUT: u32 = 0x644F7574;
const K_AUDIO_DEVICE_PROPERTY_DEVICE_NAME: u32 = 0x6E616D65;
const K_AUDIO_DEVICE_AVAILABLE_RATES: u32 = 0x6E737223;
const K_AUDIO_SCOPE_GLOBAL: u32 = 0x676C6F62;
const K_AUDIO_ELEMENT_MAIN: u32 = 0;
const K_AUDIO_OBJECT_SYSTEM: u32 = 1;

extern "C" {
    fn AudioObjectGetPropertyDataSize(
        object_id: AudioDeviceID,
        address: *const AudioObjectPropertyAddress,
        qualifier_data_size: u32,
        qualifier_data: *const std::ffi::c_void,
        data_size: *mut u32,
    ) -> OSStatus;

    fn AudioObjectGetPropertyData(
        object_id: AudioDeviceID,
        address: *const AudioObjectPropertyAddress,
        qualifier_data_size: u32,
        qualifier_data: *const std::ffi::c_void,
        data_size: *mut u32,
        data: *mut std::ffi::c_void,
    ) -> OSStatus;
}

pub(crate) fn enumerate_devices() -> Vec<OutputDeviceInfo> {
    unsafe {
        // 获取设备列表
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_DEVICES,
            scope: K_AUDIO_SCOPE_GLOBAL,
            element: K_AUDIO_ELEMENT_MAIN,
        };
        let mut data_size: u32 = 0;
        if AudioObjectGetPropertyDataSize(
            K_AUDIO_OBJECT_SYSTEM, &addr, 0, std::ptr::null(), &mut data_size,
        ) != 0 || data_size == 0 {
            return vec![];
        }

        let count = data_size as usize / std::mem::size_of::<AudioDeviceID>();
        let mut devices: Vec<AudioDeviceID> = vec![0; count];
        AudioObjectGetPropertyData(
            K_AUDIO_OBJECT_SYSTEM, &addr, 0, std::ptr::null(),
            &mut data_size, devices.as_mut_ptr() as *mut std::ffi::c_void,
        );

        // 默认输出设备
        let default_addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_DEFAULT_OUTPUT,
            scope: K_AUDIO_SCOPE_GLOBAL,
            element: K_AUDIO_ELEMENT_MAIN,
        };
        let mut default_id: AudioDeviceID = 0;
        let mut default_size = std::mem::size_of::<AudioDeviceID>() as u32;
        AudioObjectGetPropertyData(
            K_AUDIO_OBJECT_SYSTEM, &default_addr, 0, std::ptr::null(),
            &mut default_size, &mut default_id as *mut _ as *mut std::ffi::c_void,
        );

        let mut result = Vec::new();
        for &device_id in &devices {
            // 设备名（C 字符串）
            let name_addr = AudioObjectPropertyAddress {
                selector: K_AUDIO_DEVICE_PROPERTY_DEVICE_NAME,
                scope: K_AUDIO_SCOPE_GLOBAL,
                element: K_AUDIO_ELEMENT_MAIN,
            };
            let mut name_buf = [0u8; 256];
            let mut name_size = 256u32;
            let name = if AudioObjectGetPropertyData(
                device_id, &name_addr, 0, std::ptr::null(),
                &mut name_size, name_buf.as_mut_ptr() as *mut std::ffi::c_void,
            ) == 0 {
                std::ffi::CStr::from_bytes_until_nul(&name_buf)
                    .map(|c| c.to_string_lossy().to_string())
                    .unwrap_or_default()
            } else {
                String::new()
            };

            // 支持的采样率
            let rate_addr = AudioObjectPropertyAddress {
                selector: K_AUDIO_DEVICE_AVAILABLE_RATES,
                scope: K_AUDIO_SCOPE_GLOBAL,
                element: K_AUDIO_ELEMENT_MAIN,
            };
            let mut rate_size: u32 = 0;
            let configs = if AudioObjectGetPropertyDataSize(
                device_id, &rate_addr, 0, std::ptr::null(), &mut rate_size,
            ) == 0 && rate_size > 0 {
                let rate_count = rate_size as usize / std::mem::size_of::<AudioValueRange>();
                let mut ranges: Vec<AudioValueRange> = (0..rate_count)
                    .map(|_| AudioValueRange { minimum: 0.0, maximum: 0.0 })
                    .collect();
                AudioObjectGetPropertyData(
                    device_id, &rate_addr, 0, std::ptr::null(),
                    &mut rate_size, ranges.as_mut_ptr() as *mut std::ffi::c_void,
                );
                ranges.iter().filter_map(|r| {
                    let rate = r.minimum as u32;
                    if (8000..=768000).contains(&rate) && (r.minimum - r.maximum).abs() < 0.5 {
                        Some(DeviceConfig {
                            sample_rate: rate,
                            bit_depth: 24,
                            channels: 2,
                            sample_format: SampleFormat::I24,
                            exclusive: false,
                        })
                    } else { None }
                }).collect()
            } else {
                // Fallback：常见采样率
                vec![
                    DeviceConfig { sample_rate: 44100, bit_depth: 24, channels: 2, sample_format: SampleFormat::I24, exclusive: false },
                    DeviceConfig { sample_rate: 48000, bit_depth: 24, channels: 2, sample_format: SampleFormat::I24, exclusive: false },
                    DeviceConfig { sample_rate: 96000, bit_depth: 24, channels: 2, sample_format: SampleFormat::I24, exclusive: false },
                    DeviceConfig { sample_rate: 192000, bit_depth: 24, channels: 2, sample_format: SampleFormat::I24, exclusive: false },
                ]
            };

            result.push(OutputDeviceInfo {
                id: device_id.to_string(),
                name,
                is_default: device_id == default_id && default_id != 0,
                is_usb: false,
                configs,
            });
        }
        result
    }
}
