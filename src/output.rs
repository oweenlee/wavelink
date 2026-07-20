//! 音频输出抽象层
//!
//! 定义 AudioOutput trait，各平台后端分别实现。
//! - 桌面端: cpal 后端 (output_cpal)
//! - 移动端/无设备: HeadlessOutput (ringbuf → FFI)

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use ringbuf::traits::Split;
use ringbuf::{HeapCons, HeapProd, HeapRb};

/// 解码端向 ring buffer 推入样本的生产端
pub type PcmProducer = HeapProd<f32>;

/// 被音频回调和引擎线程共享的内部状态
pub struct AudioOutputInner {
    /// ringbuf 消费者端，回调通过它读取样本
    pub consumer: Mutex<HeapCons<f32>>,
    /// underrun 计数（回调读不到数据时递增）
    pub underrun_count: AtomicU64,
}

/// 音频输出 trait，各平台后端分别实现
pub trait AudioOutput {
    fn pause(&self);
    fn resume(&self);
    /// 创建新 ringbuf，原子替换消费者端（seek/切歌时用）
    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer;
}

// ─── HeadlessOutput ──────────────────────────────────────────

static HEADLESS_INNER: std::sync::Mutex<Option<Arc<AudioOutputInner>>> = std::sync::Mutex::new(None);

/// 获取 HeadlessOutput 的 AudioOutputInner（供 FFI ac_audio_read 使用）
pub(crate) fn headless_inner() -> Option<Arc<AudioOutputInner>> {
    HEADLESS_INNER.lock().ok()?.clone()
}

struct HeadlessOutput {
    inner: Arc<AudioOutputInner>,
    playing: AtomicBool,
}

impl AudioOutput for HeadlessOutput {
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
        if let Ok(mut guard) = self.inner.consumer.lock() {
            let _ = std::mem::replace(&mut *guard, new_cons);
        }
        prod
    }
}

// ─── cpal 后端 ───────────────────────────────────────────────

#[cfg(feature = "cpal-backend")]
mod output_cpal;

// ─── open ────────────────────────────────────────────────────

/// 打开输出设备。
///
/// 桌面端（cpal-backend feature）优先使用 cpal 后端连接物理设备；
/// 若 cpal 不可用或未启用 feature，回退到 HeadlessOutput（ringbuf 无输出设备）。
#[cfg_attr(not(feature = "cpal-backend"), allow(unused_variables))]
pub fn open(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    device_name: Option<&str>,
) -> Result<(Box<dyn AudioOutput>, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    #[cfg(feature = "cpal-backend")]
    {
        if let Ok(result) = output_cpal::open_inner(channels, sample_rate, buffer_ms, device_name)
        {
            return Ok((Box::new(result.0) as Box<dyn AudioOutput>, result.1, result.2, result.3));
        }
        // cpal 失败则回退到 headless（例如无可用设备时）
    }

    // Headless 模式
    let buf_samples =
        (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
    let rb = HeapRb::<f32>::new(buf_samples.max(64));
    let (prod, cons) = rb.split();
    let inner = Arc::new(AudioOutputInner {
        consumer: Mutex::new(cons),
        underrun_count: AtomicU64::new(0),
    });
    let _ = HEADLESS_INNER.lock().map(|mut g| { *g = Some(inner.clone()); });
    let out = HeadlessOutput {
        inner: inner.clone(),
        playing: AtomicBool::new(true),
    };
    Ok((Box::new(out) as Box<dyn AudioOutput>, prod, inner, sample_rate))
}

/// 列出所有可用输出设备名称（仅 cpal 后端）
#[cfg(feature = "cpal-backend")]
pub fn list_device_names() -> Vec<String> {
    output_cpal::list_device_names()
}
