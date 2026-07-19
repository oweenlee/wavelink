//! 音频输出 ringbuf：解码线程直接写入 → 平台音频输出
//!
//! iOS: ringbuf → AVAudioSourceNode (fill_buffer_stereo)

#[cfg(target_os = "ios")]
extern "C" {
    fn pthread_set_qos_class_self_np(class: u32, offset: i32) -> i32;
}

use once_cell::sync::OnceCell;
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};
use std::sync::atomic::{AtomicPtr, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::thread;

/// 硬件采样率（由 Swift 启动时通过 `set_hw_sample_rate` 设置）
static HW_SAMPLE_RATE: AtomicU32 = AtomicU32::new(44100);

/// 全局 ringbuf
static PRODUCER: OnceCell<Mutex<HeapProd<f32>>> = OnceCell::new();
static CONSUMER_PTR: AtomicPtr<HeapCons<f32>> = AtomicPtr::new(std::ptr::null_mut());
/// 保证 PRODUCER 与 CONSUMER_PTR 原子地一起初始化且仅一次
static INIT_ONCE: Once = Once::new();

// ── 频谱 / underrun 全局状态 ──
/// 最近一帧的 16 频段能量，由 consumer::run_consumer_loop 写入、Dart 轮询读取
static SPECTRUM: Mutex<[f32; 16]> = Mutex::new([0.0; 16]);
/// underrun 计数：consumer 拉到空 ringbuf 的次数
static UNDERRUN_COUNT: AtomicU64 = AtomicU64::new(0);

/// 停止信号（替代旧的 DECODER_GEN）
static STOP_FLAG: OnceCell<Mutex<Option<Arc<std::sync::atomic::AtomicBool>>>> = OnceCell::new();
/// 首帧就绪信号（consumer 发，Dart 收）
static READY_RX: OnceCell<Mutex<Option<crossbeam_channel::Receiver<bool>>>> = OnceCell::new();

/// 由 Swift 通过 extern "C" 调用，设置硬件采样率
#[no_mangle]
pub extern "C" fn set_hw_sample_rate(rate: u32) {
    HW_SAMPLE_RATE.store(rate, Ordering::Release);
}

fn ringbuf_capacity() -> usize {
    let sr = HW_SAMPLE_RATE.load(Ordering::Acquire);
    (sr as usize) * 2 * 30 // 30 秒缓冲
}

pub fn init_audio_ringbuf() {
    let cap = ringbuf_capacity();
    INIT_ONCE.call_once(|| {
        let rb = HeapRb::<f32>::new(cap);
        let (prod, cons) = rb.split();
        PRODUCER.set(Mutex::new(prod)).ok();
        let leaked = Box::leak(Box::new(cons));
        CONSUMER_PTR.store(leaked as *mut HeapCons<f32>, Ordering::Release);
        crate::api::dsp::dsp_global_init();

        STOP_FLAG.set(Mutex::new(None)).ok();
        READY_RX.set(Mutex::new(None)).ok();
    });
}

/// 读取当前频谱（16 频段，0~1）
pub fn get_spectrum() -> Vec<f32> {
    SPECTRUM.lock().map(|g| g.to_vec()).unwrap_or_default()
}

/// 等待解码器首帧就绪（consumer 线程发 ready 信号）
/// 返回 true 表示首帧已到，false 表示超时
pub fn wait_for_ready(timeout_ms: u64) -> bool {
    if let Some(mtx) = READY_RX.get() {
        if let Ok(mut g) = mtx.lock() {
            if let Some(rx) = g.take() {
                return rx.recv_timeout(std::time::Duration::from_millis(timeout_ms)).is_ok();
            }
        }
    }
    false
}

/// 读取 underrun 计数
pub fn get_underrun_count() -> u64 {
    UNDERRUN_COUNT.load(Ordering::Acquire)
}

// ── 后台解码线程 ──

pub fn start_file_decoder(path: String, seek_secs: Option<f64>) {
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    // 保存停止信号，供 stop_file_decoder 使用
    if let Some(mtx) = STOP_FLAG.get() {
        if let Ok(mut g) = mtx.lock() {
            *g = Some(stop.clone());
        }
    }

    let p = path.clone();
    let sr = HW_SAMPLE_RATE.load(Ordering::Acquire);
    thread::spawn(move || {
        #[cfg(target_os = "ios")]
        unsafe {
            pthread_set_qos_class_self_np(0x21, 0);
        }

        let (rx, _dec) = match audio_core::decoder::Decoder::start(
            std::path::Path::new(&p),
            sr,
            2,
            Arc::new(std::sync::atomic::AtomicU64::new(0)),
            seek_secs,
        ) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[audio] 解码器失败: {e}");
                return;
            }
        };

        let ch = 2u32;
        let (ready_tx, ready_rx) = crossbeam_channel::bounded::<bool>(1);
        if let Some(mtx) = READY_RX.get() {
            if let Ok(mut g) = mtx.lock() {
                *g = Some(ready_rx);
            }
        }

        let config = audio_core::consumer::ConsumerConfig {
            sample_rate: sr,
            channels: ch,
            fft_interval: 4,
            crossfade_ms: 0,
            recv_timeout_ms: 500,
        };

        audio_core::consumer::run_consumer_loop(
            rx,
            &config,
            &|s| {
                if let Some(prod) = PRODUCER.get() {
                    if let Ok(mut p) = prod.lock() {
                        return p.push_slice(s);
                    }
                }
                0
            },
            &|buf| crate::api::dsp::dsp_global_process(buf),
            &|bands| {
                if let Ok(mut g) = SPECTRUM.lock() {
                    *g = *bands;
                }
            },
            &|| {},
            &|_n| {},
            &|| None,
            &stop,
            ready_tx,
        );
    });
}

#[allow(dead_code)]
pub fn debug_occupied() -> usize {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if ptr.is_null() {
        return 0;
    }
    unsafe { (*ptr).occupied_len() }
}

pub fn stop_file_decoder() {
    // 设停止信号
    if let Some(mtx) = STOP_FLAG.get() {
        if let Ok(mut g) = mtx.lock() {
            if let Some(ref flag) = *g {
                flag.store(true, Ordering::Release);
            }
            *g = None;
        }
    }
    clear_ringbuf();
}

/// 清空 ringbuf 残留数据。供 ffi.rs 的 extern "C" 回调调用。
pub(crate) fn clear_ringbuf_impl() {
    clear_ringbuf();
}

fn clear_ringbuf() {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if !ptr.is_null() {
        unsafe {
            let c = &mut *ptr;
            let n = c.occupied_len();
            if n > 0 {
                c.advance_read_index(n);
            }
        }
    }
}

// ── 平台音频输出回调实现 ──

/// 从 ringbuf 拉取 PCM 数据填入左右声道 buffer。供 ffi.rs 的 extern "C" 回调调用。
pub(crate) unsafe fn fill_buffer_stereo_impl(
    left_out: *mut f32,
    right_out: *mut f32,
    frames: u32,
) {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if ptr.is_null() {
        return;
    }
    let cons = &mut *ptr;
    let frames = frames as usize;
    let mut done = 0usize;
    let mut buf = [0.0f32; 2048];
    let mut underrun = false;
    while done < frames {
        let want = ((frames - done) * 2).min(2048);
        let n = cons.pop_slice(&mut buf[..want]);
        let fc = n / 2;
        for i in 0..fc {
            *left_out.add(done + i) = buf[i * 2];
            *right_out.add(done + i) = buf[i * 2 + 1];
        }
        if n < want {
            for i in (done + fc)..frames {
                *left_out.add(i) = 0.0;
                *right_out.add(i) = 0.0;
            }
            underrun = true;
            break;
        }
        done += fc;
    }
    if underrun {
        UNDERRUN_COUNT.fetch_add(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::dsp::{dsp_global_apply_preset, dsp_global_init, dsp_global_process, dsp_global_set_enabled, EqPreset};

    #[test]
    fn dsp_path_applies_and_spectrum_computes() {
        dsp_global_init();
        crate::api::dsp::dsp_global_set_enabled(true);
        let mut flat = vec![0.5f32; 2048];
        dsp_global_apply_preset(EqPreset::Flat);
        dsp_global_process(&mut flat);
        let flat_copy = flat.clone();

        dsp_global_apply_preset(EqPreset::Rock);
        let mut rock = vec![0.5f32; 2048];
        dsp_global_process(&mut rock);

        let diff = flat_copy
            .iter()
            .zip(rock.iter())
            .map(|(a, b)| (a - b).abs())
            .sum::<f32>();
        assert!(diff > 0.001, "EQ 预设未改变样本，DSP 未生效，diff={diff:.4}");

        assert_eq!(get_underrun_count(), 0);
    }
}
