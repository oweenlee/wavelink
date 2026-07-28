//! 平台音频输出桥接
//!
//! 从 EngineHandle 的 HeadlessOutput ringbuf 拉取 PCM 数据，
//! 供 iOS AVAudioSourceNode 回调使用。

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

use parking_lot::Mutex as ParkingMutex;

/// 硬件采样率（由 Swift 启动时通过 `set_hw_sample_rate` 设置）
static HW_SAMPLE_RATE: AtomicU32 = AtomicU32::new(44100);

/// 最近一帧 16 频段频谱，由 engine 事件轮询写入、Dart 读取
static SPECTRUM: Mutex<[f32; 16]> = Mutex::new([0.0; 16]);
/// underrun 计数：iOS 回调从 ringbuf 读不到足够数据时递增
static UNDERRUN_COUNT: AtomicU64 = AtomicU64::new(0);

/// 由 Swift 通过 extern "C" 调用，设置硬件采样率
#[no_mangle]
pub extern "C" fn set_hw_sample_rate(rate: u32) {
    HW_SAMPLE_RATE.store(rate, Ordering::Release);
}

pub fn get_hw_sample_rate() -> u32 {
    HW_SAMPLE_RATE.load(Ordering::Acquire)
}

/// 读取当前频谱（16 频段，0~1）
pub fn get_spectrum() -> Vec<f32> {
    SPECTRUM.lock().map(|g| g.to_vec()).unwrap_or_default()
}

/// 供 engine 事件轮询更新频谱
pub(crate) fn update_spectrum(bands: &[f32; 16]) {
    if let Ok(mut g) = SPECTRUM.lock() {
        *g = *bands;
    }
}

/// 读取 underrun 计数
pub fn get_underrun_count() -> u64 {
    UNDERRUN_COUNT.load(Ordering::Acquire)
}

/// 清空 ringbuf 残留数据（平台音频流 start/stop 时调用）
pub(crate) fn clear_ringbuf_impl() {
    // EngineHandle 在 seek/切歌时自动 swap_consumer 创建新 ringbuf，
    // 无需手动清空。保留此函数为 no-op 以保持 FFI 兼容。
}

/// 预分配的实时回调缓冲区（避免在音频线程中做堆分配）
/// iOS AVAudioSourceNode 单次回调最大 4096 帧，首次回调时自动分配
static RT_BUF: ParkingMutex<Vec<f32>> = ParkingMutex::new(Vec::new());

/// 从 engine 的 HeadlessOutput ringbuf 拉取 PCM 填入左右声道 buffer
pub(crate) unsafe fn fill_buffer_stereo_impl(
    left_out: *mut f32,
    right_out: *mut f32,
    frames: u32,
) {
    let frames = frames as usize;

    // 从预分配缓冲区获取引用，避免实时线程 malloc
    let mut rt_buf = RT_BUF.lock();
    if rt_buf.len() < frames * 2 {
        rt_buf.resize(frames * 2, 0.0);
    }
    let buf: &mut [f32] = &mut (*rt_buf)[..frames * 2];

    let n = crate::api::engine::engine_read_samples(buf);

    let fc = n / 2;
    for i in 0..fc.min(frames) {
        *left_out.add(i) = buf[i * 2];
        *right_out.add(i) = buf[i * 2 + 1];
    }
    if fc < frames {
        for i in fc..frames {
            *left_out.add(i) = 0.0;
            *right_out.add(i) = 0.0;
        }
        UNDERRUN_COUNT.fetch_add(1, Ordering::AcqRel);
    }
}
