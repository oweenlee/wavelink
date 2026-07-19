//! 音频输出 ringbuf：解码线程直接写入 → 平台音频输出
//!
//! iOS:       ringbuf → AVAudioSourceNode (fill_buffer_stereo)

use once_cell::sync::OnceCell;
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};
use std::sync::atomic::{AtomicPtr, AtomicU64, Ordering};
use std::sync::{Arc, Once};
use std::thread;

/// 全局 ringbuf
static PRODUCER: OnceCell<std::sync::Mutex<HeapProd<f32>>> = OnceCell::new();
static CONSUMER_PTR: AtomicPtr<HeapCons<f32>> = AtomicPtr::new(std::ptr::null_mut());
static DECODER_GEN: AtomicU64 = AtomicU64::new(0);
/// 保证 PRODUCER 与 CONSUMER_PTR 原子地一起初始化且仅一次，
/// 否则重复 init 会让 producer 写旧 ringbuf、consumer 读新 ringbuf 导致永久错位（全静音）。
static INIT_ONCE: Once = Once::new();

const RINGBUF_CAPACITY: usize = 44100 * 2 * 6;

pub fn init_audio_ringbuf() {
    INIT_ONCE.call_once(|| {
        let rb = HeapRb::<f32>::new(RINGBUF_CAPACITY);
        let (prod, cons) = rb.split();
        PRODUCER.set(std::sync::Mutex::new(prod)).ok();
        let leaked = Box::leak(Box::new(cons));
        CONSUMER_PTR.store(leaked as *mut HeapCons<f32>, Ordering::Release);
    });
}

// ── 共享解码器 ──

fn run_decoder(path: String, seek_secs: Option<f64>, gen: u64) {
    let (rx, dec) = match audio_core::decoder::Decoder::start(
        std::path::Path::new(&path), 44100, 2,
        Arc::new(std::sync::atomic::AtomicU64::new(0)), seek_secs,
    ) {
        Ok(v) => v,
        Err(e) => { eprintln!("[audio] 解码器失败: {e}"); return; }
    };

    loop {
        if DECODER_GEN.load(Ordering::Acquire) != gen { break; }
        match rx.recv_timeout(std::time::Duration::from_millis(500)) {
            Ok(frame) => {
                let s = frame.samples;

                // 必须把整帧（可能 > ringbuf 剩余空间）全部写入，
                // 不能丢弃。用偏移量循环 push 剩余部分。
                let mut off = 0usize;
                while off < s.len() {
                    if DECODER_GEN.load(Ordering::Acquire) != gen { break; }
                    let prod = PRODUCER.get().unwrap();
                    let mut p = prod.lock().unwrap();
                    let pushed = p.push_slice(&s[off..]);
                    if pushed > 0 {
                        off += pushed;
                    } else {
                        drop(p);
                        thread::sleep(std::time::Duration::from_millis(10));
                    }
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }
    dec.stop();
}

pub fn start_file_decoder(path: String, seek_secs: Option<f64>) {
    let gen = DECODER_GEN.fetch_add(1, Ordering::AcqRel) + 1;
    let p = path.clone();
    thread::spawn(move || run_decoder(p, seek_secs, gen));
}

#[allow(dead_code)]
pub fn debug_occupied() -> usize {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if ptr.is_null() { return 0; }
    unsafe { (*ptr).occupied_len() }
}

pub fn stop_file_decoder() {
    DECODER_GEN.fetch_add(1, Ordering::AcqRel);
    clear_ringbuf();
}

/// 清空 ringbuf 残留数据（丢弃读指针之前的积压样本）。
/// 用于 iOS 暂停恢复场景：暂停期间解码线程仍在推数据，
/// resume 时丢弃积压、无缝接上实时解码，避免"磁带滑"。
#[no_mangle]
pub extern "C" fn audio_output_clear_ringbuf() {
    clear_ringbuf();
}

fn clear_ringbuf() {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if !ptr.is_null() {
        unsafe {
            let c = &mut *ptr;
            let n = c.occupied_len();
            if n > 0 { c.advance_read_index(n); }
        }
    }
}

// ── iOS: AVAudioSourceNode ──

#[no_mangle]
pub unsafe extern "C" fn audio_output_fill_buffer_stereo(
    left_out: *mut f32, right_out: *mut f32, frames: u32,
) {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if ptr.is_null() { return; }
    let cons = &mut *ptr;
    // 支持任意 frameCount：循环拉取，避免大帧（>1024）时后半段被静音截断
    let frames = frames as usize;
    let mut done = 0usize;
    let mut buf = [0.0f32; 2048];
    while done < frames {
        let want = ((frames - done) * 2).min(2048);
        let n = cons.pop_slice(&mut buf[..want]);
        let fc = n / 2;
        for i in 0..fc {
            *left_out.add(done + i) = buf[i * 2];
            *right_out.add(done + i) = buf[i * 2 + 1];
        }
        // 本批不足（ringbuf 空）→ 剩余补静音
        if n < want {
            for i in (done + fc)..frames {
                *left_out.add(i) = 0.0;
                *right_out.add(i) = 0.0;
            }
            break;
        }
        done += fc;
    }
}


