//! 音频输出 ringbuf：解码线程直接写入 → 平台音频输出
//!
//! iOS:       ringbuf → AVAudioSourceNode (fill_buffer_stereo)

use once_cell::sync::OnceCell;
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};
use std::sync::atomic::{AtomicPtr, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;

/// 全局 ringbuf
static PRODUCER: OnceCell<std::sync::Mutex<HeapProd<f32>>> = OnceCell::new();
static CONSUMER_PTR: AtomicPtr<HeapCons<f32>> = AtomicPtr::new(std::ptr::null_mut());
static DECODER_GEN: AtomicU64 = AtomicU64::new(0);

const RINGBUF_CAPACITY: usize = 44100 * 2 * 6;

pub fn init_audio_ringbuf() {
    let rb = HeapRb::<f32>::new(RINGBUF_CAPACITY);
    let (prod, cons) = rb.split();
    PRODUCER.set(std::sync::Mutex::new(prod)).ok();
    let leaked = Box::leak(Box::new(cons));
    CONSUMER_PTR.store(leaked as *mut HeapCons<f32>, Ordering::Release);
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
                let ch = frame.channels as u64;
                let sr = frame.sample_rate as u64;
                let dur = s.len() as u64 * 1000 / (ch * sr);
                thread::sleep(std::time::Duration::from_millis(if dur > 5 { dur * 8 / 10 } else { dur }));

                loop {
                    if DECODER_GEN.load(Ordering::Acquire) != gen { break; }
                    let prod = PRODUCER.get().unwrap();
                    let mut p = prod.lock().unwrap();
                    if p.push_slice(&s) > 0 { break; }
                    drop(p);
                    thread::sleep(std::time::Duration::from_millis(10));
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

pub fn stop_file_decoder() {
    DECODER_GEN.fetch_add(1, Ordering::AcqRel);
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
unsafe extern "C" fn audio_output_fill_buffer_stereo(
    left_out: *mut f32, right_out: *mut f32, frames: u32,
) {
    let ptr = CONSUMER_PTR.load(Ordering::Acquire);
    if ptr.is_null() { return; }
    let cons = &mut *ptr;
    let mut buf = [0.0f32; 2048];
    let n = cons.pop_slice(&mut buf[..(frames as usize * 2).min(2048)]);
    let fc = n / 2;
    for i in 0..fc {
        *left_out.add(i) = buf[i * 2];
        *right_out.add(i) = buf[i * 2 + 1];
    }
    for i in fc..(frames as usize) {
        *left_out.add(i) = 0.0;
        *right_out.add(i) = 0.0;
    }
}


