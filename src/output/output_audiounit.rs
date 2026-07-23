//! iOS AudioUnit (RemoteIO) 音频输出后端
//!
//! 直接在 Rust 层管理 AudioUnit，减少 Swift 桥接层。
//! 仅在 feature = "audiounit-backend" 且 target_os = "ios" 时编译。
//!
//! 特性：
//! - 直接创建 AudioUnit (kAudioUnitSubType_RemoteIO)
//! - 回调中直接从 ringbuf 拉取（零额外拷贝）
//! - 支持 AVAudioSession 采样率协商

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};

/// AudioUnit 音频输出句柄
pub struct AudioOutputUnit {
    /// AudioUnit 实例指针
    unit: coreaudio_sys::AudioUnit,
    /// 共享内部状态
    pub inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
}

// AudioUnit 是 Send（单线程创建 + 回调）
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

    fn supported_sample_rates(&self) -> Vec<u32> {
        // iOS AVAudioSession 通常支持 44100, 48000, 96000
        vec![44100, 48000, 96000]
    }
}

impl Drop for AudioOutputUnit {
    fn drop(&mut self) {
        unsafe {
            coreaudio_sys::AudioOutputUnitStop(self.unit);
            coreaudio_sys::AudioUnitUninitialize(self.unit);
            coreaudio_sys::AudioComponentInstanceDispose(self.unit);
        }
    }
}

/// 渲染回调：从 ringbuf 拉取数据填入 AudioUnit buffer
extern "C" fn render_callback(
    user_data: *mut std::ffi::c_void,
    _flags: *mut coreaudio_sys::AudioUnitRenderActionFlags,
    _timestamp: *const coreaudio_sys::AudioTimeStamp,
    _bus: u32,
    frames: u32,
    audio_data: *mut coreaudio_sys::AudioBufferList,
) -> i32 {
    let ctx = unsafe { &*(user_data as *const RenderContext) };

    if !ctx.playing.load(Ordering::Acquire) {
        // 填静音
        unsafe {
            let buf_list = &mut *audio_data;
            for i in 0..buf_list.mNumberBuffers as usize {
                let buf = &mut buf_list.mBuffers[i];
                let data = std::slice::from_raw_parts_mut(
                    buf.mData as *mut f32,
                    buf.mDataByteSize as usize / 4,
                );
                data.fill(0.0);
            }
        }
        return 0; // noErr
    }

    unsafe {
        let buf_list = &mut *audio_data;
        let total_samples = (frames as usize) * (ctx.channels as usize);
        let mut guard = ctx.inner.consumer.lock();

        for i in 0..buf_list.mNumberBuffers as usize {
            let buf = &mut buf_list.mBuffers[i];
            let data = std::slice::from_raw_parts_mut(
                buf.mData as *mut f32,
                buf.mDataByteSize as usize / 4,
            );
            let n = guard.pop_slice(data);
            if n < data.len() {
                ctx.inner.underrun_count.fetch_add(1, Ordering::Relaxed);
                data[n..].fill(0.0);
            }
        }
    }

    0 // noErr
}

/// 渲染回调上下文
struct RenderContext {
    inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    channels: u32,
}

/// 打开 AudioUnit 输出
pub(crate) fn open_inner(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
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
        // 创建 RemoteIO AudioUnit
        let mut desc = AudioComponentDescription {
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        };
        let component = AudioComponentFindNext(std::ptr::null_mut(), &desc);
        if component.is_null() {
            return Err("找不到 RemoteIO AudioUnit".into());
        }

        let mut unit: AudioUnit = std::ptr::null_mut();
        let status = AudioComponentInstanceNew(component, &mut unit);
        if status != 0 {
            return Err(format!("AudioComponentInstanceNew 失败: {status}"));
        }

        // 启用输出
        let enable: u32 = 1;
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enable as *const _ as *const _,
            std::mem::size_of::<u32>() as u32,
        );

        // 设置流格式
        let mut stream_desc = AudioStreamBasicDescription {
            mSampleRate: sample_rate as f64,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0,
        };
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &stream_desc as *const _ as *const _,
            std::mem::size_of::<AudioStreamBasicDescription>() as u32,
        );

        // 设置渲染回调
        let ctx = Box::new(RenderContext {
            inner: inner.clone(),
            playing: playing.clone(),
            channels,
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
        let status = AudioUnitInitialize(unit);
        if status != 0 {
            AudioComponentInstanceDispose(unit);
            return Err(format!("AudioUnitInitialize 失败: {status}"));
        }

        info!("AudioUnit 输出: {}Hz {}ch", sample_rate, channels);

        let output = AudioOutputUnit {
            unit,
            inner: inner.clone(),
            playing,
            sample_rate,
            channels,
            buffer_ms,
        };

        Ok((output, producer, inner, sample_rate))
    }
}
