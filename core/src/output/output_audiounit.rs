//! macOS/iOS AudioUnit 音频输出后端
//!
//! macOS: HAL Output AudioUnit (kAudioUnitSubType_HALOutput)，支持设备选择 + 整数直出
//! iOS: RemoteIO AudioUnit (kAudioUnitSubType_RemoteIO)
//!
//! 相比 cpal 的优势：延迟更低、支持整数格式输出（bit-perfect 前提）

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer, SampleFormat};

// ─── 平台常量 ────────────────────────────────────────────────

#[cfg(target_os = "macos")]
const AUDIO_OUTPUT_SUBTYPE: u32 = 0x6168616C; // 'ahal' = kAudioUnitSubType_HALOutput

#[cfg(target_os = "ios")]
const AUDIO_OUTPUT_SUBTYPE: u32 = 0x72696F63; // 'rioc' = kAudioUnitSubType_RemoteIO

// ─── AudioOutputUnit ─────────────────────────────────────────

pub struct AudioOutputUnit {
    unit: coreaudio_sys::AudioUnit,
    inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
    sample_format: SampleFormat,
    /// render callback 的 user_data 指针（Box::into_raw 得来，Drop 释放）。
    render_ctx: *mut RenderContext,
}

unsafe impl Send for AudioOutputUnit {}

impl AudioOutput for AudioOutputUnit {
    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
        unsafe {
            coreaudio_sys::AudioOutputUnitStop(self.unit);
        }
    }

    fn resume(&self) {
        self.playing.store(true, Ordering::Release);
        unsafe {
            coreaudio_sys::AudioOutputUnitStart(self.unit);
        }
    }

    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer {
        let buf_samples =
            (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (prod, new_cons) = rb.split();
        let mut guard = self.inner.consumer.lock();
        guard.clear();
        *guard = new_cons;
        prod
    }

    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
    fn channels(&self) -> u32 {
        self.channels
    }
    fn sample_format(&self) -> SampleFormat {
        self.sample_format
    }

    fn supported_sample_rates(&self) -> Vec<u32> {
        vec![44100, 48000, 88200, 96000, 176400, 192000]
    }

    fn set_bit_depth(&mut self, depth: u16) {
        let fmt = match depth {
            16 => SampleFormat::I16,
            32 => SampleFormat::I32,
            _ => SampleFormat::F32,
        };
        self.sample_format = fmt;
    }
}

impl Drop for AudioOutputUnit {
    fn drop(&mut self) {
        unsafe {
            coreaudio_sys::AudioOutputUnitStop(self.unit);
            coreaudio_sys::AudioUnitUninitialize(self.unit);
            coreaudio_sys::AudioComponentInstanceDispose(self.unit);
            // 释放 render callback 的 Box，避免每次 open 泄漏一份 RenderContext。
            if !self.render_ctx.is_null() {
                drop(Box::from_raw(self.render_ctx));
                self.render_ctx = std::ptr::null_mut();
            }
        }
    }
}

// ─── 渲染回调 ────────────────────────────────────────────────

struct RenderContext {
    inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    channels: u32,
    sample_format: SampleFormat,
    tmp_buf: Vec<f32>,
}

extern "C" fn render_callback(
    user_data: *mut std::ffi::c_void,
    _flags: *mut coreaudio_sys::AudioUnitRenderActionFlags,
    _timestamp: *const coreaudio_sys::AudioTimeStamp,
    _bus: u32,
    frames: u32,
    audio_data: *mut coreaudio_sys::AudioBufferList,
) -> i32 {
    let ctx = unsafe { &mut *(user_data as *mut RenderContext) };

    if !ctx.playing.load(Ordering::Acquire) {
        unsafe {
            let buf_list = &mut *audio_data;
            for i in 0..buf_list.mNumberBuffers as usize {
                let buf = &mut buf_list.mBuffers[i];
                std::ptr::write_bytes(buf.mData, 0u8, buf.mDataByteSize as usize);
            }
        }
        return 0;
    }

    let total_frames = frames as usize;
    let ch = ctx.channels as usize;
    let total_samples = total_frames * ch;

    unsafe {
        let buf_list = &mut *audio_data;
        let mut guard = ctx.inner.consumer.lock();

        match ctx.sample_format {
            SampleFormat::F32 => {
                if buf_list.mNumberBuffers <= 1 {
                    // 单 buffer：按交错 PCM 直接填充。
                    let buf = &mut buf_list.mBuffers[0];
                    let data = std::slice::from_raw_parts_mut(
                        buf.mData as *mut f32,
                        buf.mDataByteSize as usize / 4,
                    );
                    let n = guard.pop_slice(data);
                    if n < data.len() {
                        ctx.inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                        data[n..].fill(0.0);
                    }
                } else {
                    // 多 buffer：CoreAudio 非交错 per-channel 布局。
                    // 先从交错 ringbuf 读出完整帧，再按声道解交织写入各 buffer。
                    ctx.tmp_buf.resize(total_samples.max(64), 0.0);
                    let n = guard.pop_slice(&mut ctx.tmp_buf[..total_samples]);
                    if n < total_samples {
                        ctx.inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                        ctx.tmp_buf[n..total_samples].fill(0.0);
                    }
                    for i in 0..buf_list.mNumberBuffers as usize {
                        if i >= ch {
                            break;
                        }
                        let buf = &mut buf_list.mBuffers[i];
                        let data = std::slice::from_raw_parts_mut(
                            buf.mData as *mut f32,
                            buf.mDataByteSize as usize / 4,
                        );
                        for (dst, src) in data.iter_mut().zip(ctx.tmp_buf[i..].iter().step_by(ch)) {
                            *dst = *src;
                        }
                    }
                }
            }
            SampleFormat::I16 | SampleFormat::I32 => {
                ctx.tmp_buf.resize(total_samples.max(64), 0.0);
                let n = guard.pop_slice(&mut ctx.tmp_buf[..total_samples]);
                if n < total_samples {
                    ctx.inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                    ctx.tmp_buf[n..total_samples].fill(0.0);
                }

                let mut si = 0;
                for i in 0..buf_list.mNumberBuffers as usize {
                    let buf = &mut buf_list.mBuffers[i];
                    let sample_count = buf.mDataByteSize as usize
                        / if ctx.sample_format == SampleFormat::I16 {
                            2
                        } else {
                            4
                        };
                    match ctx.sample_format {
                        SampleFormat::I16 => {
                            let data =
                                std::slice::from_raw_parts_mut(buf.mData as *mut i16, sample_count);
                            for dst in data.iter_mut() {
                                *dst = (ctx.tmp_buf[si].clamp(-1.0, 1.0) * 32768.0)
                                    .round()
                                    .clamp(-32768.0, 32767.0)
                                    as i16;
                                si += 1;
                            }
                        }
                        SampleFormat::I32 => {
                            let data =
                                std::slice::from_raw_parts_mut(buf.mData as *mut i32, sample_count);
                            for dst in data.iter_mut() {
                                // 2^31 缩放 + round：DoP 左对齐 24-bit 字逐比特无损
                                *dst = (ctx.tmp_buf[si].clamp(-1.0, 1.0) * 2147483648.0)
                                    .round()
                                    .clamp(-2147483648.0, 2147483647.0)
                                    as i32;
                                si += 1;
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    0 // noErr
}

// ─── 格式辅助 ────────────────────────────────────────────────

fn asbd_from_format(
    format: SampleFormat,
    sample_rate: f64,
    channels: u32,
) -> coreaudio_sys::AudioStreamBasicDescription {
    let ch = channels as u32;
    match format {
        SampleFormat::F32 => coreaudio_sys::AudioStreamBasicDescription {
            mSampleRate: sample_rate,
            mFormatID: coreaudio_sys::kAudioFormatLinearPCM,
            mFormatFlags: coreaudio_sys::kAudioFormatFlagIsFloat
                | coreaudio_sys::kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * ch,
            mChannelsPerFrame: ch,
            mBitsPerChannel: 32,
            mReserved: 0,
        },
        SampleFormat::I16 => coreaudio_sys::AudioStreamBasicDescription {
            mSampleRate: sample_rate,
            mFormatID: coreaudio_sys::kAudioFormatLinearPCM,
            mFormatFlags: coreaudio_sys::kAudioFormatFlagIsSignedInteger
                | coreaudio_sys::kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * ch,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * ch,
            mChannelsPerFrame: ch,
            mBitsPerChannel: 16,
            mReserved: 0,
        },
        SampleFormat::I32 | SampleFormat::I24 => coreaudio_sys::AudioStreamBasicDescription {
            mSampleRate: sample_rate,
            mFormatID: coreaudio_sys::kAudioFormatLinearPCM,
            mFormatFlags: coreaudio_sys::kAudioFormatFlagIsSignedInteger
                | coreaudio_sys::kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * ch,
            mChannelsPerFrame: ch,
            mBitsPerChannel: 32,
            mReserved: 0,
        },
    }
}

fn negotiate_format(
    unit: coreaudio_sys::AudioUnit,
    channels: u32,
    sample_rate: u32,
    bit_depth: u16,
) -> SampleFormat {
    // 优先尝试 bit-perfect 请求的格式
    if bit_depth > 0 {
        let fmt = match bit_depth {
            16 => SampleFormat::I16,
            24 | 32 => SampleFormat::I32,
            _ => SampleFormat::F32,
        };
        let desc = asbd_from_format(fmt, sample_rate as f64, channels);
        let status = unsafe {
            coreaudio_sys::AudioUnitSetProperty(
                unit,
                coreaudio_sys::kAudioUnitProperty_StreamFormat,
                coreaudio_sys::kAudioUnitScope_Output,
                0,
                &desc as *const _ as *const std::ffi::c_void,
                std::mem::size_of::<coreaudio_sys::AudioStreamBasicDescription>() as u32,
            )
        };
        if status == 0 {
            return fmt;
        }
        warn!(
            "AudioUnit 不支持整数格式 (bit_depth={}), 回退 Float32",
            bit_depth
        );
    }

    SampleFormat::F32
}

// ─── open_inner ──────────────────────────────────────────────

pub(crate) fn open_inner(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    device_name: Option<&str>,
    bit_depth: u16,
) -> Result<(AudioOutputUnit, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    use coreaudio_sys::*;

    let buf_samples = (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
    let rb = HeapRb::<f32>::new(buf_samples.max(64));
    let (producer, consumer) = rb.split();

    let inner = Arc::new(AudioOutputInner {
        consumer: parking_lot::Mutex::new(consumer),
        underrun_count: std::sync::atomic::AtomicU64::new(0),
        stream_failed: std::sync::atomic::AtomicBool::new(false),
    });

    let playing = Arc::new(AtomicBool::new(false));

    unsafe {
        let mut desc = AudioComponentDescription {
            componentType: kAudioUnitType_Output,
            componentSubType: AUDIO_OUTPUT_SUBTYPE,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        };
        let component = AudioComponentFindNext(std::ptr::null_mut(), &desc);
        if component.is_null() {
            return Err("找不到 AudioUnit 输出组件".into());
        }

        let mut unit: AudioUnit = std::ptr::null_mut();
        let status = AudioComponentInstanceNew(component, &mut unit);
        if status != 0 {
            return Err(format!("AudioComponentInstanceNew 失败: {status}"));
        }

        // 启用输出 (element 0)
        let enable: u32 = 1;
        let hr = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enable as *const _ as *const _,
            std::mem::size_of::<u32>() as u32,
        );
        if hr != 0 {
            AudioComponentInstanceDispose(unit);
            return Err(format!("启用输出失败: {hr}"));
        }

        // 设置目标设备（macOS HALOutput 专用）
        #[cfg(target_os = "macos")]
        if let Some(name) = device_name {
            if let Some(dev_id) = find_device_id_by_name(name) {
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &dev_id as *const _ as *const _,
                    std::mem::size_of::<u32>() as u32,
                );
            } else {
                warn!("未找到设备 '{name}'，使用默认输出");
            }
        }

        // 协商格式：尝试整数 → 回退 Float32
        let sample_format = negotiate_format(unit, channels, sample_rate, bit_depth);

        // 设置实际使用的流格式（input scope = 我们的回调格式）
        let desc = asbd_from_format(sample_format, sample_rate as f64, channels);
        let hr = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &desc as *const _ as *const _,
            std::mem::size_of::<AudioStreamBasicDescription>() as u32,
        );
        if hr != 0 {
            AudioComponentInstanceDispose(unit);
            return Err(format!("设置流格式失败: {hr}"));
        }

        // 设置渲染回调
        let ctx = Box::new(RenderContext {
            inner: inner.clone(),
            playing: playing.clone(),
            channels,
            sample_format,
            tmp_buf: Vec::new(),
        });
        let ctx_ptr = Box::into_raw(ctx);

        let mut callback = AURenderCallbackStruct {
            inputProc: Some(render_callback),
            inputProcRefCon: ctx_ptr as *mut _,
        };
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Global,
            0,
            &mut callback as *mut _ as *const _,
            std::mem::size_of::<AURenderCallbackStruct>() as u32,
        );

        // 初始化
        let hr = AudioUnitInitialize(unit);
        if hr != 0 {
            drop(Box::from_raw(ctx_ptr));
            AudioComponentInstanceDispose(unit);
            return Err(format!("AudioUnitInitialize 失败: {hr}"));
        }

        info!(
            "AudioUnit 输出: {}Hz {}ch 格式:{:?}",
            sample_rate, channels, sample_format
        );

        let output = AudioOutputUnit {
            unit,
            inner: inner.clone(),
            playing,
            sample_rate,
            channels,
            buffer_ms,
            sample_format,
            render_ctx: ctx_ptr,
        };

        Ok((output, producer, inner, sample_rate))
    }
}

// ─── macOS 设备名→ID 查找 ─────────────────────────────────────

#[cfg(target_os = "macos")]
unsafe fn find_device_id_by_name(name: &str) -> Option<u32> {
    use coreaudio_sys::*;

    let addr = AudioObjectPropertyAddress {
        mSelector: 0x6465766D, // kAudioHardwarePropertyDevices
        mScope: 0x676C6F62,    // kAudioObjectPropertyScopeGlobal
        mElement: 0,
    };

    let mut data_size: u32 = 0;
    let hr = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &addr,
        0,
        std::ptr::null(),
        &mut data_size,
    );
    if hr != 0 || data_size == 0 {
        return None;
    }

    let count = data_size as usize / std::mem::size_of::<u32>();
    let mut ids: Vec<u32> = vec![0; count];
    let mut size = data_size;
    AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &addr,
        0,
        std::ptr::null(),
        &mut size,
        ids.as_mut_ptr() as *mut std::ffi::c_void,
    );

    for &dev_id in &ids {
        let name_addr = AudioObjectPropertyAddress {
            mSelector: 0x6E616D65, // kAudioDevicePropertyDeviceName
            mScope: 0x676C6F62,    // kAudioObjectPropertyScopeGlobal
            mElement: 0,
        };
        let mut buf = [0u8; 256];
        let mut name_size = 256u32;
        let hr = AudioObjectGetPropertyData(
            dev_id,
            &name_addr,
            0,
            std::ptr::null(),
            &mut name_size,
            buf.as_mut_ptr() as *mut std::ffi::c_void,
        );
        if hr == 0 {
            if let Ok(n) = std::ffi::CStr::from_bytes_until_nul(&buf) {
                if n.to_string_lossy() == name {
                    return Some(dev_id);
                }
            }
        }
    }

    None
}

// macOS CoreAudio FFI 声明（与 output_coreaudio.rs 不冲突，均为 extern "C"）
#[cfg(target_os = "macos")]
extern "C" {
    fn AudioObjectGetPropertyDataSize(
        object_id: u32,
        address: *const AudioObjectPropertyAddress,
        qualifier_data_size: u32,
        qualifier_data: *const std::ffi::c_void,
        data_size: *mut u32,
    ) -> i32;

    fn AudioObjectGetPropertyData(
        object_id: u32,
        address: *const AudioObjectPropertyAddress,
        qualifier_data_size: u32,
        qualifier_data: *const std::ffi::c_void,
        data_size: *mut u32,
        data: *mut std::ffi::c_void,
    ) -> i32;
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct AudioObjectPropertyAddress {
    mSelector: u32,
    mScope: u32,
    mElement: u32,
}
