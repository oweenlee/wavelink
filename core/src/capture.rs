//! 音频输入捕获抽象层
//!
//! 定义 AudioCapture trait 和全局捕获管理器。
//! - 桌面端: cpal 后端，通过全局状态管理（避免 cpal::Stream !Send 问题）
//! - 移动端: 由平台层直接管理

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;
#[cfg(feature = "cpal-backend")]
use ringbuf::traits::{Producer, Split};
use ringbuf::HeapCons;
#[cfg(feature = "cpal-backend")]
use ringbuf::HeapRb;

/// 捕获缓冲消费者端（供宿主层读取）
pub struct CaptureInner {
    /// 捕获数据的环缓冲消费者端
    pub consumer: Mutex<HeapCons<f32>>,
}

static CAPTURE_INNER: Mutex<Option<Arc<CaptureInner>>> = Mutex::new(None);

/// 获取全局捕获缓冲（供宿主层读取捕获数据）
pub(crate) fn capture_inner() -> Option<Arc<CaptureInner>> {
    CAPTURE_INNER.lock().clone()
}

// ─── 全局捕获管理器 ────────────────────────────────────────────

/// 捕获运行状态
static CAPTURE_ACTIVE: AtomicBool = AtomicBool::new(false);

/// 捕获线程停止信号发送端（drop 即通知线程退出）
#[cfg(feature = "cpal-backend")]
static CAPTURE_STOP: Mutex<Option<crossbeam_channel::Sender<()>>> = Mutex::new(None);
/// 捕获线程 JoinHandle
#[cfg(feature = "cpal-backend")]
static CAPTURE_THREAD: Mutex<Option<std::thread::JoinHandle<()>>> = Mutex::new(None);

/// 开始捕获。返回 Ok(()) 表示成功。
///
/// cpal::Stream 是 !Send，无法跨线程传递。改为在专用线程内创建并持有 stream，
/// 通过 channel 信号控制生命周期，避免裸指针。
#[cfg(feature = "cpal-backend")]
pub fn start_global_capture(sample_rate: u32, channels: u32) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    if CAPTURE_ACTIVE.load(Ordering::Acquire) {
        return Err("捕获已在运行中".to_string());
    }

    let rb = HeapRb::<f32>::new(65536);
    let (mut prod, cons) = rb.split();
    let inner = Arc::new(CaptureInner {
        consumer: Mutex::new(cons),
    });
    *CAPTURE_INNER.lock() = Some(inner);

    let (stop_tx, stop_rx) = crossbeam_channel::bounded::<()>(1);
    // 用于等待线程内 stream 创建成功的应答
    let (ready_tx, ready_rx) = crossbeam_channel::bounded::<Result<(), String>>(1);

    let handle = std::thread::Builder::new()
        .name("audio-capture".into())
        .spawn(move || {
            let host = cpal::default_host();
            let device = match host.default_input_device() {
                Some(d) => d,
                None => {
                    let _ = ready_tx.send(Err("未找到输入设备".into()));
                    return;
                }
            };
            let config = cpal::StreamConfig {
                channels: channels as u16,
                sample_rate: cpal::SampleRate(sample_rate),
                buffer_size: cpal::BufferSize::Default,
            };
            let err_fn = |err| tracing::error!("捕获回调错误: {err}");
            let stream = match device.build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    let n = prod.push_slice(data);
                    if n < data.len() {
                        tracing::warn!("捕获缓冲满，丢弃 {} 样本", data.len() - n);
                    }
                },
                err_fn,
                None,
            ) {
                Ok(s) => s,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("构建输入流失败: {e}")));
                    return;
                }
            };
            if let Err(e) = stream.play() {
                let _ = ready_tx.send(Err(format!("启动输入流失败: {e}")));
                return;
            }
            let _ = ready_tx.send(Ok(()));
            // stream 活在此线程栈上，阻塞等待停止信号
            let _ = stop_rx.recv();
            // recv 返回（stop 信号或 sender 被 drop）→ stream 自然 drop
            tracing::debug!("捕获线程退出");
        })
        .map_err(|e| format!("启动捕获线程失败: {e}"))?;

    // 等待线程内 stream 创建结果
    match ready_rx.recv_timeout(std::time::Duration::from_secs(5)) {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            *CAPTURE_INNER.lock() = None;
            return Err(e);
        }
        Err(_) => {
            *CAPTURE_INNER.lock() = None;
            return Err("捕获线程启动超时".into());
        }
    }

    *CAPTURE_STOP.lock() = Some(stop_tx);
    *CAPTURE_THREAD.lock() = Some(handle);
    CAPTURE_ACTIVE.store(true, Ordering::Release);
    Ok(())
}

/// 停止捕获
#[cfg(feature = "cpal-backend")]
pub fn stop_global_capture() {
    if !CAPTURE_ACTIVE.load(Ordering::Acquire) {
        return;
    }
    // 发送停止信号（或 drop sender），捕获线程退出后 stream 自然 drop
    if let Some(tx) = CAPTURE_STOP.lock().take() {
        let _ = tx.send(());
    }
    if let Some(handle) = CAPTURE_THREAD.lock().take() {
        let _ = handle.join();
    }
    CAPTURE_ACTIVE.store(false, Ordering::Release);
    *CAPTURE_INNER.lock() = None;
}

/// 是否正在捕获
pub fn is_capturing() -> bool {
    CAPTURE_ACTIVE.load(Ordering::Acquire)
}

// ─── 非 cpal 平台无操作实现 ──────────────────────────────────

/// 开始捕获（非 cpal 平台无实际操作，仅置位运行标志）。
#[cfg(not(feature = "cpal-backend"))]
pub fn start_global_capture(_sample_rate: u32, _channels: u32) -> Result<(), String> {
    CAPTURE_ACTIVE.store(true, Ordering::Release);
    Ok(())
}

/// 停止捕获（非 cpal 平台无实际操作，仅清除运行标志与缓冲）。
#[cfg(not(feature = "cpal-backend"))]
pub fn stop_global_capture() {
    CAPTURE_ACTIVE.store(false, Ordering::Release);
    *CAPTURE_INNER.lock() = None;
}
