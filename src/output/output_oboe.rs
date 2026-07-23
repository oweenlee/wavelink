//! Android Oboe/AAudio 音频输出后端
//!
//! 使用 `oboe` crate（Rust binding for Oboe/AAudio）。
//! 仅在 feature = "oboe-backend" 且 target_os = "android" 时编译。
//!
//! 特性：
//! - 原生支持 Exclusive Mode（AAudio）
//! - 支持动态采样率切换
//! - 低延迟回调

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};

/// Oboe 音频输出句柄
pub struct AudioOutputOboe {
    /// Oboe 音频流（持有以保持生命周期）
    _stream: oboe::AudioStream,
    /// 共享内部状态
    pub inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    sample_rate: u32,
    channels: u32,
    buffer_ms: u32,
}

impl AudioOutput for AudioOutputOboe {
    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
    }

    fn resume(&self) {
        self.playing.store(true, Ordering::Release);
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

    fn set_sample_rate(&mut self, rate: u32) -> Result<u32, crate::error::EngineError> {
        if rate == self.sample_rate {
            return Ok(rate);
        }
        // Oboe 需要重建 stream 来切换采样率
        // TODO: 实现 Oboe stream 重建
        warn!("Oboe 采样率切换暂未实现，保持 {}Hz", self.sample_rate);
        Ok(self.sample_rate)
    }

    fn supported_sample_rates(&self) -> Vec<u32> {
        // AAudio 通常支持 44100, 48000, 96000, 192000
        vec![44100, 48000, 96000, 192000]
    }
}

/// 打开 Oboe 输出
pub(crate) fn open_inner(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    exclusive: bool,
) -> Result<(AudioOutputOboe, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    use oboe::{AudioStreamBuilder, AudioOutputStreamSafe, PerformanceMode, SharingMode};

    let buf_samples = (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
    let rb = HeapRb::<f32>::new(buf_samples.max(64));
    let (producer, consumer) = rb.split();

    let inner = Arc::new(AudioOutputInner {
        consumer: parking_lot::Mutex::new(consumer),
        underrun_count: std::sync::atomic::AtomicU64::new(0),
        stream_failed: std::sync::atomic::AtomicBool::new(false),
    });

    let playing = Arc::new(AtomicBool::new(false));
    let playing_clone = playing.clone();
    let inner_clone = inner.clone();

    let sharing = if exclusive {
        SharingMode::Exclusive
    } else {
        SharingMode::Shared
    };

    // 构建 Oboe 输出流
    let stream = AudioStreamBuilder::default()
        .set_output()
        .set_f32()
        .set_channels(channels as i32)
        .set_sample_rate(sample_rate as i32)
        .set_sharing_mode(sharing)
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_callback(move |_, buffer: &mut [f32]| {
            if !playing_clone.load(Ordering::Acquire) {
                buffer.fill(0.0);
                return;
            }
            let mut guard = inner_clone.consumer.lock();
            let n = guard.pop_slice(buffer);
            if n < buffer.len() {
                inner_clone.underrun_count.fetch_add(1, Ordering::Relaxed);
                buffer[n..].fill(0.0);
            }
        })
        .open_stream()
        .map_err(|e| format!("Oboe 打开失败: {e:?}"))?;

    let actual_rate = stream.sample_rate() as u32;
    info!("Oboe 输出: {}Hz {}ch, exclusive={}", actual_rate, channels, exclusive);

    let output = AudioOutputOboe {
        _stream: stream,
        inner: inner.clone(),
        playing,
        sample_rate: actual_rate,
        channels,
        buffer_ms,
    };

    Ok((output, producer, inner, actual_rate))
}
