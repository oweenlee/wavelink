//! 音频输出抽象层
//!
//! 定义 AudioOutput trait，各平台后端（cpal/AudioUnit/Oboe）分别实现。
//! 当前桌面端使用 cpal 后端（output_cpal）。

use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};

use ringbuf::{HeapCons, HeapProd};

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

mod output_cpal;

/// 打开默认输出设备
pub fn open(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    device_name: Option<&str>,
) -> Result<(Box<dyn AudioOutput>, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    let (out, prod, inner, rate) = output_cpal::open_inner(channels, sample_rate, buffer_ms, device_name)?;
    Ok((Box::new(out), prod, inner, rate))
}

/// 列出所有可用输出设备名称
pub fn list_device_names() -> Vec<String> {
    output_cpal::list_device_names()
}
