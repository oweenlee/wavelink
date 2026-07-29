//! Windows WASAPI Exclusive 模式输出后端
//!
//! 使用 windows-sys 直接 FFI 调用 WASAPI COM 接口，
//! 绕过 cpal 实现独占模式 + 整数样本输出。
//!
//! 仅 Windows + wasapi-backend feature 时编译。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer, SampleFormat};

// ─── windows-sys 导入 ────────────────────────────────────────

use windows_sys::Win32::Foundation::{CloseHandle, FALSE, HANDLE};
use windows_sys::core::HRESULT;
use windows_sys::Win32::Media::Audio::{
    AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    WAVEFORMATEX, WAVEFORMATEXTENSIBLE, WAVEFORMATEXTENSIBLE_0,
};
use windows_sys::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows_sys::Win32::System::Threading::{CreateEventW, SetEvent, WaitForSingleObject, INFINITE,
    GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_TIME_CRITICAL};

// ─── GUID 常量 ───────────────────────────────────────────────

const CLSID_MMDEVICE_ENUMERATOR: windows_sys::core::GUID =
    windows_sys::core::GUID {
        data1: 0xBCDE0395,
        data2: 0xE52F,
        data3: 0x467C,
        data4: [0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E],
    };

const IID_IMMDEVICE_ENUMERATOR: windows_sys::core::GUID =
    windows_sys::core::GUID {
        data1: 0xA95664D2,
        data2: 0x9614,
        data3: 0x4F35,
        data4: [0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6],
    };

const IID_IAUDIO_CLIENT: windows_sys::core::GUID =
    windows_sys::core::GUID {
        data1: 0x1CB9AD4C,
        data2: 0xDBFA,
        data3: 0x4C32,
        data4: [0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2],
    };

const IID_IAUDIO_RENDER_CLIENT: windows_sys::core::GUID =
    windows_sys::core::GUID {
        data1: 0xF294ACFC,
        data2: 0x3146,
        data3: 0x4483,
        data4: [0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2],
    };

const KSDATAFORMAT_SUBTYPE_PCM: windows_sys::core::GUID =
    windows_sys::core::GUID {
        data1: 0x00000001,
        data2: 0x0000,
        data3: 0x0010,
        data4: [0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71],
    };

const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: windows_sys::core::GUID =
    windows_sys::core::GUID {
        data1: 0x00000003,
        data2: 0x0000,
        data3: 0x0010,
        data4: [0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71],
    };

// ─── COM Vtables ─────────────────────────────────────────────

#[repr(C)]
struct IUnknownVtbl {
    query_interface: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add_ref: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    release: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
}

#[repr(C)]
struct IMMDeviceEnumeratorVtbl {
    qi: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    rel: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    enum_audio_endpoints: unsafe extern "system" fn(*mut std::ffi::c_void, u32, u32, *mut *mut std::ffi::c_void) -> HRESULT,
    get_default_audio_endpoint: unsafe extern "system" fn(*mut std::ffi::c_void, u32, u32, *mut *mut std::ffi::c_void) -> HRESULT,
    get_device: unsafe extern "system" fn(*mut std::ffi::c_void, *const u16, *mut *mut std::ffi::c_void) -> HRESULT,
}

#[repr(C)]
struct IMMDeviceVtbl {
    qi: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    rel: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    activate: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, u32, *mut std::ffi::c_void, *mut *mut std::ffi::c_void) -> HRESULT,
    open_property_store: unsafe extern "system" fn(*mut std::ffi::c_void, u32, *mut *mut std::ffi::c_void) -> HRESULT,
    get_id: unsafe extern "system" fn(*mut std::ffi::c_void, *mut *mut u16) -> HRESULT,
    get_state: unsafe extern "system" fn(*mut std::ffi::c_void, *mut u32) -> HRESULT,
}

#[repr(C)]
struct IAudioClientVtbl {
    qi: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    rel: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    initialize: unsafe extern "system" fn(*mut std::ffi::c_void, u32, u32, i64, i64, *const WAVEFORMATEX, *const windows_sys::core::GUID) -> HRESULT,
    get_buffer_size: unsafe extern "system" fn(*mut std::ffi::c_void, *mut u32) -> HRESULT,
    get_stream_latency: unsafe extern "system" fn(*mut std::ffi::c_void, *mut i64) -> HRESULT,
    get_current_padding: unsafe extern "system" fn(*mut std::ffi::c_void, *mut u32) -> HRESULT,
    is_format_supported: unsafe extern "system" fn(*mut std::ffi::c_void, u32, *const WAVEFORMATEX, *mut *mut WAVEFORMATEX) -> HRESULT,
    get_mix_format: unsafe extern "system" fn(*mut std::ffi::c_void, *mut *mut WAVEFORMATEX) -> HRESULT,
    get_device_period: unsafe extern "system" fn(*mut std::ffi::c_void, *mut i64, *mut i64) -> HRESULT,
    start: unsafe extern "system" fn(*mut std::ffi::c_void) -> HRESULT,
    stop: unsafe extern "system" fn(*mut std::ffi::c_void) -> HRESULT,
    reset: unsafe extern "system" fn(*mut std::ffi::c_void) -> HRESULT,
    set_event_handle: unsafe extern "system" fn(*mut std::ffi::c_void, HANDLE) -> HRESULT,
    get_service: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
}

#[repr(C)]
struct IAudioRenderClientVtbl {
    qi: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    rel: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    get_buffer: unsafe extern "system" fn(*mut std::ffi::c_void, u32, *mut *mut u8) -> HRESULT,
    release_buffer: unsafe extern "system" fn(*mut std::ffi::c_void, u32, u32) -> HRESULT,
}

// ─── COM 辅助 ────────────────────────────────────────────────

unsafe fn release_com(ptr: *mut std::ffi::c_void) {
    if ptr.is_null() { return; }
    let vtbl = *(ptr as *mut *mut IUnknownVtbl);
    ((*vtbl).release)(ptr);
}

/// 裸指针包装，使其可跨线程传递（渲染线程独占使用这些 COM 指针，故 Send 是安全的）。
/// 指针本身是 Copy，包装不影响主线程继续使用原始指针。
struct SendPtr(*mut std::ffi::c_void);
unsafe impl Send for SendPtr {}
impl SendPtr {
    /// 消费包装取出指针。用方法调用（而非闭包内 `.0` 字段访问）
    /// 可避免 Rust 2021 分离捕获直接抓到裸指针而丢失 Send。
    fn into_inner(self) -> *mut std::ffi::c_void {
        self.0
    }
}

// ─── 格式定义 ────────────────────────────────────────────────

impl SampleFormat {
    fn bits_per_sample(self) -> u16 {
        match self { SampleFormat::I16 => 16, SampleFormat::I24 => 24, SampleFormat::I32 => 32, SampleFormat::F32 => 32 }
    }
    fn block_align(self, channels: u16) -> u16 {
        match self { SampleFormat::I16 => channels * 2, SampleFormat::I24 => channels * 3, SampleFormat::I32 | SampleFormat::F32 => channels * 4 }
    }
    fn avg_bytes_per_sec(self, sample_rate: u32, channels: u16) -> u32 {
        sample_rate * self.block_align(channels) as u32
    }
    fn sub_format(self) -> windows_sys::core::GUID {
        match self { SampleFormat::I16 | SampleFormat::I24 | SampleFormat::I32 => KSDATAFORMAT_SUBTYPE_PCM, SampleFormat::F32 => KSDATAFORMAT_SUBTYPE_IEEE_FLOAT }
    }
}

fn create_waveformatextensible(format: SampleFormat, channels: u16, sample_rate: u32) -> WAVEFORMATEXTENSIBLE {
    let bits = format.bits_per_sample();
    let block_align = format.block_align(channels);
    let avg_bytes = format.avg_bytes_per_sec(sample_rate, channels);
    WAVEFORMATEXTENSIBLE {
        Format: WAVEFORMATEX {
            wFormatTag: 0xFFFE,
            nChannels: channels,
            nSamplesPerSec: sample_rate,
            nAvgBytesPerSec: avg_bytes,
            nBlockAlign: block_align,
            wBitsPerSample: bits,
            cbSize: 22,
        },
        Samples: WAVEFORMATEXTENSIBLE_0 { wValidBitsPerSample: bits },
        dwChannelMask: 0x0003,
        SubFormat: format.sub_format(),
    }
}

// ─── 格式协商 ────────────────────────────────────────────────

/// windows-sys 0.59 的 GUID 未实现 PartialEq，手动逐字段比较
fn guid_eq(a: &windows_sys::core::GUID, b: &windows_sys::core::GUID) -> bool {
    a.data1 == b.data1 && a.data2 == b.data2 && a.data3 == b.data3 && a.data4 == b.data4
}

/// 解析 WASAPI 返回的 WAVEFORMATEX（含 extensible）为 (采样率, 声道数, 样本格式)
unsafe fn parse_waveformat(ptr: *const WAVEFORMATEX) -> Option<(u32, u16, SampleFormat)> {
    if ptr.is_null() {
        return None;
    }
    let wfx = &*ptr;
    let rate = wfx.nSamplesPerSec;
    let ch = wfx.nChannels;
    let bits = wfx.wBitsPerSample;
    let fmt = if wfx.wFormatTag == 0xFFFE {
        // WAVE_FORMAT_EXTENSIBLE：看 SubFormat 区分 PCM / IEEE float
        let ext = &*(ptr as *const WAVEFORMATEXTENSIBLE);
        // packed 结构体的字段不能直接取引用，先按值拷贝出来（GUID 是 Copy）
        let sub_format = ext.SubFormat;
        if guid_eq(&sub_format, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
            SampleFormat::F32
        } else {
            match bits { 16 => SampleFormat::I16, 24 => SampleFormat::I24, _ => SampleFormat::I32 }
        }
    } else if wfx.wFormatTag == 3 {
        // WAVE_FORMAT_IEEE_FLOAT
        SampleFormat::F32
    } else {
        match bits { 16 => SampleFormat::I16, 24 => SampleFormat::I24, _ => SampleFormat::I32 }
    };
    Some((rate, ch, fmt))
}

unsafe fn negotiate_format(
    client: *mut std::ffi::c_void,
    channels: u16,
    sample_rate: u32,
    source_bit_depth: Option<u16>,
    share_mode: u32,
) -> Option<(WAVEFORMATEXTENSIBLE, SampleFormat)> {
    // 共享模式：直接采用设备 mix format（共享下只有 mix format 保证可用）
    if share_mode == AUDCLNT_SHAREMODE_SHARED as u32 {
        let vtbl = *(client as *mut *mut IAudioClientVtbl);
        let mut mix: *mut WAVEFORMATEX = std::ptr::null_mut();
        let hr = ((*vtbl).get_mix_format)(client, &mut mix);
        if hr != 0 || mix.is_null() {
            warn!("WASAPI 获取 mix format 失败: 0x{hr:08X}");
            return None;
        }
        let parsed = parse_waveformat(mix);
        CoTaskMemFree(mix as *mut std::ffi::c_void);
        let (rate, mix_ch, fmt) = parsed?;
        if mix_ch != channels {
            warn!("WASAPI 共享模式: mix format 为 {mix_ch}ch，与请求 {channels}ch 不一致");
        }
        let wfx = create_waveformatextensible(fmt, channels, rate);
        info!("WASAPI 共享模式 mix format: {rate}Hz {channels}ch {fmt:?}");
        return Some((wfx, fmt));
    }

    // 独占模式：构造尝试顺序，优先 source_bit_depth，再 fallback
    let mut try_formats = Vec::new();
    if let Some(bits) = source_bit_depth {
        match bits {
            16 => try_formats.push(SampleFormat::I16),
            24 => try_formats.push(SampleFormat::I24),
            32 => try_formats.push(SampleFormat::I32),
            _ => try_formats.push(SampleFormat::I24),
        }
    }
    // 补充 fallback 列表（去重）
    for f in [SampleFormat::I24, SampleFormat::I16, SampleFormat::F32, SampleFormat::I32] {
        if !try_formats.contains(&f) {
            try_formats.push(f);
        }
    }

    let rates = [sample_rate, 48000, 44100, 96000, 192000, 88200, 176400];

    for fmt in &try_formats {
        for &rate in &rates {
            let wfx = create_waveformatextensible(*fmt, channels, rate);
            let vtbl = *(client as *mut *mut IAudioClientVtbl);
            let mut closest: *mut WAVEFORMATEX = std::ptr::null_mut();
            let hr = ((*vtbl).is_format_supported)(client, share_mode, &wfx.Format, &mut closest);
            if hr == 0 {
                info!("WASAPI 格式支持: {}Hz {}ch {:?}", rate, channels, fmt);
                return Some((wfx, *fmt));
            }
            if !closest.is_null() {
                release_com(closest as *mut std::ffi::c_void);
            }
        }
    }
    None
}

// ─── 渲染线程 ────────────────────────────────────────────────

fn render_thread(
    audio_client: *mut std::ffi::c_void,
    render_client: *mut std::ffi::c_void,
    event_handle: HANDLE,
    inner: Arc<AudioOutputInner>,
    buffer_size: u32,
    channels: u32,
    sample_format: SampleFormat,
    stop_flag: Arc<AtomicBool>,
) {
    unsafe {
        CoInitializeEx(std::ptr::null_mut(), COINIT_MULTITHREADED as u32);
        // 提升渲染线程为实时优先级，减少 underrun
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);

        let mut tmp_buf: Vec<f32> = Vec::new();

        loop {
            WaitForSingleObject(event_handle, INFINITE);

            if stop_flag.load(Ordering::Acquire) {
                break;
            }

            // 查询当前已填充帧数
            let vtbl = *(audio_client as *mut *mut IAudioClientVtbl);
            let mut padding: u32 = 0;
            ((*vtbl).get_current_padding)(audio_client, &mut padding);

            let frames_avail = buffer_size.saturating_sub(padding);
            if frames_avail == 0 {
                continue;
            }

            let samples_needed = frames_avail as usize * channels as usize;

            // 从 WASAPI 获取输出缓冲区
            let render_vtbl = *(render_client as *mut *mut IAudioRenderClientVtbl);
            let mut buf_ptr: *mut u8 = std::ptr::null_mut();
            let hr = ((*render_vtbl).get_buffer)(render_client, frames_avail, &mut buf_ptr);
            if hr != 0 || buf_ptr.is_null() {
                if hr as u32 == 0x88890004 {
                    error!("WASAPI 设备已断开");
                    inner.stream_failed.store(true, std::sync::atomic::Ordering::Release);
                    break;
                }
                error!("WASAPI GetBuffer 失败: HRESULT=0x{hr:08X}");
                continue;
            }

            // 从 ringbuf 读取样本
            let mut guard = inner.consumer.lock();
            tmp_buf.resize(samples_needed, 0.0);
            let n = guard.pop_slice(&mut tmp_buf[..samples_needed]);
            let underrun = n < samples_needed;

            match sample_format {
                SampleFormat::I16 => {
                    let dst = std::slice::from_raw_parts_mut(buf_ptr as *mut i16, samples_needed);
                    for i in 0..n {
                        dst[i] = (tmp_buf[i].clamp(-1.0, 1.0) * 32768.0) as i16;
                    }
                    if underrun { dst[n..].fill(0); }
                }
                SampleFormat::I24 => {
                    for i in 0..n {
                        let val = (tmp_buf[i].clamp(-1.0, 1.0) * 8388607.0) as i32;
                        let dest = buf_ptr.add(i * 3);
                        dest.write(val as u8);
                        dest.add(1).write((val >> 8) as u8);
                        dest.add(2).write((val >> 16) as u8);
                    }
                    if underrun {
                        std::ptr::write_bytes(buf_ptr.add(n * 3), 0u8, (samples_needed - n) * 3);
                    }
                }
                SampleFormat::F32 => {
                    let dst = std::slice::from_raw_parts_mut(buf_ptr as *mut f32, samples_needed);
                    dst[..n].copy_from_slice(&tmp_buf[..n]);
                    if underrun { dst[n..].fill(0.0); }
                }
                SampleFormat::I32 => {
                    let dst = std::slice::from_raw_parts_mut(buf_ptr as *mut i32, samples_needed);
                    for i in 0..n {
                        dst[i] = (tmp_buf[i].clamp(-1.0, 1.0) * 2147483647.0) as i32;
                    }
                    if underrun { dst[n..].fill(0); }
                }
            }

            drop(guard);

            if underrun {
                inner.underrun_count.fetch_add(1, Ordering::Relaxed);
            }

            ((*render_vtbl).release_buffer)(render_client, frames_avail, 0);
        }

        CoUninitialize();
    }
}

// ─── AudioOutputWasapi ───────────────────────────────────────

pub struct AudioOutputWasapi {
    inner: Arc<AudioOutputInner>,
    sample_rate: u32,
    channels: u32,

    enumerator: *mut std::ffi::c_void,
    mm_device: *mut std::ffi::c_void,
    audio_client: *mut std::ffi::c_void,
    render_client: *mut std::ffi::c_void,

    render_thread: Option<JoinHandle<()>>,
    stop_flag: Arc<AtomicBool>,
    event_handle: HANDLE,

    bit_depth: u16,
    com_inited: bool,
}

unsafe impl Send for AudioOutputWasapi {}
unsafe impl Sync for AudioOutputWasapi {}

impl AudioOutput for AudioOutputWasapi {
    fn pause(&self) {
        unsafe { call_audio_client_stop(self.audio_client); }
    }

    fn resume(&self) {
        unsafe { let _ = call_audio_client_start(self.audio_client); }
    }

    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer {
        let buf_samples = (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (prod, new_cons) = rb.split();
        let mut guard = self.inner.consumer.lock();
        let _ = std::mem::replace(&mut *guard, new_cons);
        prod
    }

    fn sample_rate(&self) -> u32 { self.sample_rate }
    fn channels(&self) -> u32 { self.channels }
    fn supported_sample_rates(&self) -> Vec<u32> { vec![self.sample_rate] }

    fn set_bit_depth(&mut self, depth: u16) {
        self.bit_depth = depth;
    }
}

unsafe fn call_audio_client_stop(client: *mut std::ffi::c_void) {
    if client.is_null() { return; }
    let vtbl = *(client as *mut *mut IAudioClientVtbl);
    ((*vtbl).stop)(client);
}

unsafe fn call_audio_client_start(client: *mut std::ffi::c_void) -> Result<(), String> {
    let vtbl = *(client as *mut *mut IAudioClientVtbl);
    let hr = ((*vtbl).start)(client);
    if hr != 0 { return Err(format!("Start 失败: 0x{hr:08X}")); }
    Ok(())
}

impl Drop for AudioOutputWasapi {
    fn drop(&mut self) {
        unsafe {
            self.stop_flag.store(true, Ordering::Release);
            SetEvent(self.event_handle);

            if let Some(handle) = self.render_thread.take() {
                let _ = handle.join();
            }

            call_audio_client_stop(self.audio_client);
            // 主线程统一释放所有 COM 对象
            release_com(self.render_client);
            release_com(self.audio_client);
            release_com(self.mm_device);
            release_com(self.enumerator);

            if !self.event_handle.is_null() {
                CloseHandle(self.event_handle);
            }

            if self.com_inited {
                CoUninitialize();
            }
        }
    }
}

// ─── open_inner ──────────────────────────────────────────────

/// 一次成功的 Activate → 协商 → Initialize → 取服务 的结果
struct StreamInit {
    audio_client: *mut std::ffi::c_void,
    render_client: *mut std::ffi::c_void,
    event_handle: HANDLE,
    buffer_size: u32,
    actual_rate: u32,
    sample_format: SampleFormat,
}

/// 在指定 share mode 下激活设备并初始化音频流。失败时自行清理已创建的 COM 对象
/// （audio_client / event_handle）；mm_device / enumerator 由调用方管理。
///
/// 注意：Initialize 失败后 IAudioClient 不可复用，故降级时需重新 Activate（由调用方重试）。
unsafe fn init_audio_stream(
    mm_device: *mut std::ffi::c_void,
    share_mode: u32,
    ch: u16,
    sample_rate: u32,
    source_bit_depth: Option<u16>,
    buffer_ms: u32,
) -> Result<StreamInit, String> {
    // Activate IAudioClient
    let dev_vtbl = *(mm_device as *mut *mut IMMDeviceVtbl);
    let mut audio_client: *mut std::ffi::c_void = std::ptr::null_mut();
    let hr = ((*dev_vtbl).activate)(mm_device, &IID_IAUDIO_CLIENT, CLSCTX_ALL, std::ptr::null_mut(), &mut audio_client);
    if hr != 0 || audio_client.is_null() {
        return Err(format!("激活 IAudioClient 失败: 0x{hr:08X}"));
    }

    // 格式协商
    let (wfx, sample_format) = match negotiate_format(audio_client, ch, sample_rate, source_bit_depth, share_mode) {
        Some(f) => f,
        None => {
            release_com(audio_client);
            return Err(format!("设备不支持 {sample_rate}Hz {ch}ch 的可用格式"));
        }
    };

    // 创建事件句柄
    let event_handle = CreateEventW(std::ptr::null_mut(), FALSE, FALSE, std::ptr::null());
    if event_handle.is_null() {
        release_com(audio_client);
        return Err("创建音频事件句柄失败".into());
    }

    let actual_rate = wfx.Format.nSamplesPerSec;
    let buffer_hns = (buffer_ms as i64) * 10000;

    // 初始化
    let ac_vtbl = *(audio_client as *mut *mut IAudioClientVtbl);
    let hr = ((*ac_vtbl).initialize)(audio_client, share_mode, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, buffer_hns, 0, &wfx.Format, std::ptr::null());
    if hr != 0 {
        let err = if hr as u32 == 0x8889000A { "设备被其他应用占用".into() } else { format!("Initialize 失败: 0x{hr:08X}") };
        CloseHandle(event_handle); release_com(audio_client);
        return Err(err);
    }

    // SetEventHandle
    let hr = ((*ac_vtbl).set_event_handle)(audio_client, event_handle);
    if hr != 0 {
        CloseHandle(event_handle); release_com(audio_client);
        return Err(format!("SetEventHandle 失败: 0x{hr:08X}"));
    }

    // 缓冲区大小
    let mut buffer_size: u32 = 0;
    let hr = ((*ac_vtbl).get_buffer_size)(audio_client, &mut buffer_size);
    if hr != 0 { buffer_size = (actual_rate as f32 * buffer_ms as f32 / 1000.0) as u32; }

    // 获取 IAudioRenderClient
    let mut render_client: *mut std::ffi::c_void = std::ptr::null_mut();
    let hr = ((*ac_vtbl).get_service)(audio_client, &IID_IAUDIO_RENDER_CLIENT, &mut render_client);
    if hr != 0 || render_client.is_null() {
        CloseHandle(event_handle); release_com(audio_client);
        return Err(format!("GetService 失败: 0x{hr:08X}"));
    }

    Ok(StreamInit { audio_client, render_client, event_handle, buffer_size, actual_rate, sample_format })
}

pub(crate) fn open_inner(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    device_name: Option<&str>,
    bit_depth: u16,
    exclusive: bool,
) -> Result<(AudioOutputWasapi, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    unsafe {
        CoInitializeEx(std::ptr::null_mut(), COINIT_MULTITHREADED as u32);

        // 创建枚举器
        let mut enumerator: *mut std::ffi::c_void = std::ptr::null_mut();
        let hr = CoCreateInstance(
            &CLSID_MMDEVICE_ENUMERATOR, std::ptr::null_mut(), CLSCTX_ALL,
            &IID_IMMDEVICE_ENUMERATOR, &mut enumerator,
        );
        if hr != 0 { CoUninitialize(); return Err(format!("创建 MMDeviceEnumerator 失败: 0x{hr:08X}")); }

        // 获取设备
        let mm_device = if let Some(name) = device_name {
            let vtbl = *(enumerator as *mut *mut IMMDeviceEnumeratorVtbl);
            let mut device: *mut std::ffi::c_void = std::ptr::null_mut();
            let name_wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
            let hr = ((*vtbl).get_device)(enumerator, name_wide.as_ptr(), &mut device);
            if hr != 0 || device.is_null() {
                release_com(enumerator); CoUninitialize();
                return Err(format!("未找到设备: {name}"));
            }
            device
        } else {
            let vtbl = *(enumerator as *mut *mut IMMDeviceEnumeratorVtbl);
            let mut device: *mut std::ffi::c_void = std::ptr::null_mut();
            let hr = ((*vtbl).get_default_audio_endpoint)(enumerator, 0, 0, &mut device);
            if hr != 0 || device.is_null() {
                release_com(enumerator); CoUninitialize();
                return Err("未找到默认输出设备".into());
            }
            device
        };

        // 选择 share mode 并初始化音频流；独占失败自动降级到共享（同一设备/后端）
        let ch = channels as u16;
        let source_bit_depth = if bit_depth > 0 { Some(bit_depth) } else { None };
        let (init, is_exclusive) = if exclusive {
            match init_audio_stream(mm_device, AUDCLNT_SHAREMODE_EXCLUSIVE as u32, ch, sample_rate, source_bit_depth, buffer_ms) {
                Ok(r) => (r, true),
                Err(e) => {
                    warn!("WASAPI 独占模式失败（{e}），降级到共享模式");
                    let r = init_audio_stream(mm_device, AUDCLNT_SHAREMODE_SHARED as u32, ch, sample_rate, source_bit_depth, buffer_ms)
                        .map_err(|e2| {
                            release_com(mm_device); release_com(enumerator); CoUninitialize();
                            format!("独占失败: {e}；共享降级也失败: {e2}")
                        })?;
                    (r, false)
                }
            }
        } else {
            let r = init_audio_stream(mm_device, AUDCLNT_SHAREMODE_SHARED as u32, ch, sample_rate, source_bit_depth, buffer_ms)
                .map_err(|e| {
                    release_com(mm_device); release_com(enumerator); CoUninitialize();
                    e
                })?;
            (r, false)
        };

        let StreamInit { audio_client, render_client, event_handle, buffer_size, actual_rate, sample_format } = init;

        // Ringbuf
        let buf_samples = (actual_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (prod, cons) = rb.split();
        let inner = Arc::new(AudioOutputInner {
            consumer: parking_lot::Mutex::new(cons),
            underrun_count: std::sync::atomic::AtomicU64::new(0),
            stream_failed: std::sync::atomic::AtomicBool::new(false),
        });

        // 启动渲染线程
        let stop_flag = Arc::new(AtomicBool::new(false));
        let render_inner = Arc::clone(&inner);
        let render_stop = Arc::clone(&stop_flag);

        let ac_ptr = SendPtr(audio_client);
        let rc_ptr = SendPtr(render_client);
        let ev_ptr = SendPtr(event_handle);
        let render_handle = thread::Builder::new().name("wasapi-render".into()).spawn(move || {
            render_thread(ac_ptr.into_inner(), rc_ptr.into_inner(), ev_ptr.into_inner(), render_inner, buffer_size, channels, sample_format, render_stop);
        }).map_err(|e| format!("创建渲染线程失败: {e}"))?;

        // 启动音频流
        let ac_vtbl = *(audio_client as *mut *mut IAudioClientVtbl);
        let hr = ((*ac_vtbl).start)(audio_client);
        if hr != 0 {
            stop_flag.store(true, Ordering::Release);
            SetEvent(event_handle);
            let _ = render_handle.join();
            CloseHandle(event_handle); release_com(render_client); release_com(audio_client); release_com(mm_device); release_com(enumerator); CoUninitialize();
            return Err(format!("Start 失败: 0x{hr:08X}"));
        }

        let mode_name = if is_exclusive { "Exclusive" } else { "Shared" };
        info!("WASAPI {mode_name}: {actual_rate}Hz {channels}ch, 格式: {sample_format:?}, {buffer_size} 帧");

        Ok((AudioOutputWasapi {
            inner: inner.clone(), sample_rate: actual_rate, channels: channels.max(2),
            enumerator, mm_device, audio_client, render_client,
            render_thread: Some(render_handle), stop_flag, event_handle,
            bit_depth,
            com_inited: true,
        }, prod, inner, actual_rate))
    }
}

// ─── 设备枚举 vtable ─────────────────────────────────────────

#[repr(C)]
struct IMMDeviceCollectionVtbl {
    qi: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    rel: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    get_count: unsafe extern "system" fn(*mut std::ffi::c_void, *mut u32) -> HRESULT,
    item: unsafe extern "system" fn(*mut std::ffi::c_void, u32, *mut *mut std::ffi::c_void) -> HRESULT,
}

#[repr(C)]
struct IPropertyStoreVtbl {
    qi: unsafe extern "system" fn(*mut std::ffi::c_void, *const windows_sys::core::GUID, *mut *mut std::ffi::c_void) -> HRESULT,
    add: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    rel: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
    get_count: unsafe extern "system" fn(*mut std::ffi::c_void, *mut u32) -> HRESULT,
    get_at: unsafe extern "system" fn(*mut std::ffi::c_void, u32, *mut PROPERTYKEY) -> HRESULT,
    get_value: unsafe extern "system" fn(*mut std::ffi::c_void, *const PROPERTYKEY, *mut PROPVARIANT) -> HRESULT,
    set_value: unsafe extern "system" fn(*mut std::ffi::c_void, *const PROPERTYKEY, *const PROPVARIANT) -> HRESULT,
    commit: unsafe extern "system" fn(*mut std::ffi::c_void) -> HRESULT,
}

#[repr(C)]
struct PROPVARIANT {
    vt: u16,
    w_reserved1: u16,
    w_reserved2: u16,
    w_reserved3: u16,
    payload: [u8; 16],
}

impl PROPVARIANT {
    fn new() -> Self {
        Self { vt: 0, w_reserved1: 0, w_reserved2: 0, w_reserved3: 0, payload: [0u8; 16] }
    }

    fn pwsz_val(&self) -> *mut u16 {
        unsafe { std::ptr::read_unaligned(self.payload.as_ptr() as *const *mut u16) }
    }

    unsafe fn clear(&mut self) {
        if self.vt == 31 {
            let ptr = self.pwsz_val();
            if !ptr.is_null() {
                CoTaskMemFree(ptr as *mut std::ffi::c_void);
            }
        }
        self.vt = 0;
    }
}

#[repr(C)]
struct PROPERTYKEY {
    fmtid: windows_sys::core::GUID,
    pid: u32,
}

const PKEY_DEVICE_FRIENDLY_NAME: PROPERTYKEY = PROPERTYKEY {
    fmtid: windows_sys::core::GUID {
        data1: 0xa45c254e,
        data2: 0xdf1c,
        data3: 0x4efd,
        data4: [0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0],
    },
    pid: 14,
};

const PKEY_DEVICE_ENUMERATOR_NAME: PROPERTYKEY = PROPERTYKEY {
    fmtid: windows_sys::core::GUID {
        data1: 0xa45c254e,
        data2: 0xdf1c,
        data3: 0x4efd,
        data4: [0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0],
    },
    pid: 24,
};

extern "system" {
    fn CoTaskMemFree(pv: *mut std::ffi::c_void);
}

// ─── 枚举辅助 ────────────────────────────────────────────────

unsafe fn get_device_string_property(
    device: *mut std::ffi::c_void,
    key: &PROPERTYKEY,
) -> Option<String> {
    let dev_vtbl = *(device as *mut *mut IMMDeviceVtbl);
    let mut store: *mut std::ffi::c_void = std::ptr::null_mut();
    let hr = ((*dev_vtbl).open_property_store)(device, 0, &mut store);
    if hr != 0 || store.is_null() {
        return None;
    }
    let store_vtbl = *(store as *mut *mut IPropertyStoreVtbl);
    let mut pv = PROPVARIANT::new();
    let hr = ((*store_vtbl).get_value)(store, key, &mut pv);
    let result = if hr == 0 && pv.vt == 31 {
        let pwstr = pv.pwsz_val();
        if !pwstr.is_null() {
            let len = (0..).find(|&i| *pwstr.offset(i) == 0).unwrap_or(0);
            Some(String::from_utf16_lossy(std::slice::from_raw_parts(pwstr, len as usize)))
        } else { None }
    } else { None };
    pv.clear();
    release_com(store);
    result
}

unsafe fn get_device_friendly_name(device: *mut std::ffi::c_void) -> Option<String> {
    get_device_string_property(device, &PKEY_DEVICE_FRIENDLY_NAME)
}

unsafe fn is_usb_device(device: *mut std::ffi::c_void) -> bool {
    get_device_string_property(device, &PKEY_DEVICE_ENUMERATOR_NAME)
        .as_deref()
        .map(|n| n.contains("USB"))
        .unwrap_or(false)
}

unsafe fn get_default_device_id(enumerator: *mut std::ffi::c_void) -> String {
    let vtbl = *(enumerator as *mut *mut IMMDeviceEnumeratorVtbl);
    let mut device: *mut std::ffi::c_void = std::ptr::null_mut();
    let hr = ((*vtbl).get_default_audio_endpoint)(enumerator, 0, 0, &mut device);
    if hr != 0 || device.is_null() {
        return String::new();
    }
    let dev_vtbl = *(device as *mut *mut IMMDeviceVtbl);
    let mut id_ptr: *mut u16 = std::ptr::null_mut();
    let hr_id = ((*dev_vtbl).get_id)(device, &mut id_ptr);
    let id = if hr_id == 0 && !id_ptr.is_null() {
        let len = (0..).find(|&i| *id_ptr.offset(i) == 0).unwrap_or(0);
        let s = String::from_utf16_lossy(std::slice::from_raw_parts(id_ptr, len as usize));
        CoTaskMemFree(id_ptr as *mut std::ffi::c_void);
        s
    } else {
        String::new()
    };
    release_com(device);
    id
}

unsafe fn probe_device_configs(device: *mut std::ffi::c_void) -> Vec<crate::output::DeviceConfig> {
    let dev_vtbl = *(device as *mut *mut IMMDeviceVtbl);
    let mut audio_client: *mut std::ffi::c_void = std::ptr::null_mut();
    let hr = ((*dev_vtbl).activate)(device, &IID_IAUDIO_CLIENT, CLSCTX_ALL, std::ptr::null_mut(), &mut audio_client);
    if hr != 0 || audio_client.is_null() {
        return vec![];
    }
    let test_rates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000];
    let test_formats = [SampleFormat::I16, SampleFormat::I24, SampleFormat::I32, SampleFormat::F32];
    let mut configs = Vec::new();
    let ac_vtbl = *(audio_client as *mut *mut IAudioClientVtbl);
    for fmt in &test_formats {
        for &rate in &test_rates {
            let wfx = create_waveformatextensible(*fmt, 2, rate);
            let mut closest: *mut WAVEFORMATEX = std::ptr::null_mut();
            let hr = ((*ac_vtbl).is_format_supported)(audio_client, AUDCLNT_SHAREMODE_EXCLUSIVE as u32, &wfx.Format, &mut closest);
            if hr == 0 {
                configs.push(crate::output::DeviceConfig {
                    sample_rate: rate,
                    bit_depth: fmt.bits_per_sample() as u8,
                    channels: 2,
                    sample_format: *fmt,
                    exclusive: true,
                });
            }
            if !closest.is_null() {
                release_com(closest as *mut std::ffi::c_void);
            }
        }
    }
    release_com(audio_client);
    configs
}

// ─── 设备枚举 ────────────────────────────────────────────────

pub(crate) fn enumerate_devices() -> Vec<crate::output::OutputDeviceInfo> {
    unsafe {
        CoInitializeEx(std::ptr::null_mut(), COINIT_MULTITHREADED as u32);
        let mut enumerator: *mut std::ffi::c_void = std::ptr::null_mut();
        let hr = CoCreateInstance(
            &CLSID_MMDEVICE_ENUMERATOR, std::ptr::null_mut(), CLSCTX_ALL,
            &IID_IMMDEVICE_ENUMERATOR, &mut enumerator,
        );
        if hr != 0 || enumerator.is_null() {
            CoUninitialize();
            return vec![];
        }

        let default_id = get_default_device_id(enumerator);

        let enum_vtbl = *(enumerator as *mut *mut IMMDeviceEnumeratorVtbl);
        let mut collection: *mut std::ffi::c_void = std::ptr::null_mut();
        let hr = ((*enum_vtbl).enum_audio_endpoints)(enumerator, 0, 1, &mut collection);
        if hr != 0 || collection.is_null() {
            release_com(enumerator);
            CoUninitialize();
            return vec![];
        }

        let coll_vtbl = *(collection as *mut *mut IMMDeviceCollectionVtbl);
        let mut count: u32 = 0;
        ((*coll_vtbl).get_count)(collection, &mut count);
        let mut result = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut device: *mut std::ffi::c_void = std::ptr::null_mut();
            let hr = ((*coll_vtbl).item)(collection, i, &mut device);
            if hr != 0 || device.is_null() {
                continue;
            }
            let dev_vtbl = *(device as *mut *mut IMMDeviceVtbl);
            // 获取 ID
            let mut id_ptr: *mut u16 = std::ptr::null_mut();
            let hr_id = ((*dev_vtbl).get_id)(device, &mut id_ptr);
            let id = if hr_id == 0 && !id_ptr.is_null() {
                let len = (0..).find(|&i| *id_ptr.offset(i) == 0).unwrap_or(0);
                let s = String::from_utf16_lossy(std::slice::from_raw_parts(id_ptr, len as usize));
                CoTaskMemFree(id_ptr as *mut std::ffi::c_void);
                s
            } else {
                String::new()
            };
            // 获取友好名 + USB 总线判断 + 格式探测
            let name = get_device_friendly_name(device).unwrap_or_else(|| id.clone());
            let usb = is_usb_device(device);
            let configs = probe_device_configs(device);
            result.push(crate::output::OutputDeviceInfo {
                id,
                name,
                is_default: false,
                is_usb: usb,
                configs,
            });
            release_com(device);
        }

        release_com(collection);
        release_com(enumerator);
        CoUninitialize();

        // 标记默认设备
        if !default_id.is_empty() {
            if let Some(first) = result.iter_mut().find(|d| d.id == default_id) {
                first.is_default = true;
            }
        }
        result
    }
}

/// 列出所有 WASAPI 输出设备友好名称
pub(crate) fn list_device_names() -> Vec<String> {
    let devices = enumerate_devices();
    devices.into_iter().map(|d| d.name).collect()
}
