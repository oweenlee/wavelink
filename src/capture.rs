//! 音频输入捕获抽象层
//!
//! 定义 AudioCapture trait 和全局捕获管理器。
//! - 桌面端: cpal 后端，通过全局状态管理（避免 cpal::Stream !Send 问题）
//! - 移动端: 由平台层直接管理

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ringbuf::traits::{Producer, Split};
use ringbuf::{HeapCons, HeapRb};

/// 捕获缓冲消费者端（供 FFI 读取）
pub struct CaptureInner {
    /// 捕获数据的环缓冲消费者端
    pub consumer: Mutex<HeapCons<f32>>,
}

static CAPTURE_INNER: Mutex<Option<Arc<CaptureInner>>> = Mutex::new(None);

/// 获取全局捕获缓冲（供 FFI `ac_audio_read_capture` 使用）
pub(crate) fn capture_inner() -> Option<Arc<CaptureInner>> {
    CAPTURE_INNER.lock().ok()?.clone()
}

// ─── 全局捕获管理器 ────────────────────────────────────────────

/// 捕获运行状态
static CAPTURE_ACTIVE: AtomicBool = AtomicBool::new(false);

/// 开始捕获。返回 Ok(true) 表示成功。
#[cfg(feature = "cpal-backend")]
pub fn start_global_capture(sample_rate: u32, channels: u32) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    if CAPTURE_ACTIVE.load(Ordering::Acquire) {
        return Err("捕获已在运行中".to_string());
    }

    let host = cpal::default_host();
    let device = host.default_input_device()
        .ok_or_else(|| "未找到输入设备".to_string())?;
    let config = cpal::StreamConfig {
        channels: channels as u16,
        sample_rate: cpal::SampleRate(sample_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    let rb = HeapRb::<f32>::new(65536);
    let (mut prod, cons) = rb.split();
    let inner = Arc::new(CaptureInner {
        consumer: Mutex::new(cons),
    });
    let _ = CAPTURE_INNER.lock().map(|mut g| { *g = Some(inner); });

    let err_fn = |err| tracing::error!("捕获回调错误: {err}");

    let stream = device.build_input_stream(
        &config,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            let n = prod.push_slice(data);
            if n < data.len() {
                tracing::warn!("捕获缓冲满，丢弃 {} 样本", data.len() - n);
            }
        },
        err_fn,
        None,
    ).map_err(|e| format!("构建输入流失败: {e}"))?;

    stream.play().map_err(|e| format!("启动输入流失败: {e}"))?;
    // 将 stream 泄漏为 'static，通过全局状态管理生命周期
    let stream_ptr = Box::into_raw(Box::new(stream));
    // 存入全局（仅用于 stop 时 drop）
    GLOBAL_STREAM.store(stream_ptr as usize, Ordering::Release);
    CAPTURE_ACTIVE.store(true, Ordering::Release);
    Ok(())
}

/// 全局 stream 指针，仅用于 stop 时重建 Box 并 drop
static GLOBAL_STREAM: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// 停止捕获
#[cfg(feature = "cpal-backend")]
pub fn stop_global_capture() {
    if !CAPTURE_ACTIVE.load(Ordering::Acquire) {
        return;
    }
    let ptr = GLOBAL_STREAM.swap(0, Ordering::AcqRel);
    if ptr != 0 {
        // 重建 Box 自动 drop，停止 stream
        let _ = unsafe { Box::from_raw(ptr as *mut cpal::Stream) };
    }
    CAPTURE_ACTIVE.store(false, Ordering::Release);
    let _ = CAPTURE_INNER.lock().map(|mut g| { *g = None; });
}

/// 是否正在捕获
pub fn is_capturing() -> bool {
    CAPTURE_ACTIVE.load(Ordering::Acquire)
}

// ─── 非 cpal 平台无操作实现 ──────────────────────────────────

#[cfg(not(feature = "cpal-backend"))]
pub fn start_global_capture(_sample_rate: u32, _channels: u32) -> Result<(), String> {
    CAPTURE_ACTIVE.store(true, Ordering::Release);
    Ok(())
}

#[cfg(not(feature = "cpal-backend"))]
pub fn stop_global_capture() {
    CAPTURE_ACTIVE.store(false, Ordering::Release);
    let _ = CAPTURE_INNER.lock().map(|mut g| { *g = None; });
}
