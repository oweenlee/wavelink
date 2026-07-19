//! 音频输出 ringbuf：解码线程直接写入 → 平台音频输出
//!
//! iOS:       ringbuf → AVAudioSourceNode (fill_buffer_stereo)

use once_cell::sync::OnceCell;
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};
use std::sync::atomic::{AtomicPtr, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::thread;
use realfft::num_complex::Complex;

/// 全局 ringbuf
static PRODUCER: OnceCell<std::sync::Mutex<HeapProd<f32>>> = OnceCell::new();
static CONSUMER_PTR: AtomicPtr<HeapCons<f32>> = AtomicPtr::new(std::ptr::null_mut());
static DECODER_GEN: AtomicU64 = AtomicU64::new(0);
/// 保证 PRODUCER 与 CONSUMER_PTR 原子地一起初始化且仅一次，
/// 否则重复 init 会让 producer 写旧 ringbuf、consumer 读新 ringbuf 导致永久错位（全静音）。
static INIT_ONCE: Once = Once::new();

// ── 频谱 / underrun 全局状态 ──
const SPECTRUM_BANDS: usize = 16;
/// 最近一帧的 16 频段能量（已平滑，0~1），由解码线程写入、Dart 轮询读取
static SPECTRUM: Mutex<[f32; SPECTRUM_BANDS]> = Mutex::new([0.0; SPECTRUM_BANDS]);
/// underrun 计数：consumer 拉到空 ringbuf 的次数
static UNDERRUN_COUNT: AtomicU64 = AtomicU64::new(0);

const RINGBUF_CAPACITY: usize = 44100 * 2 * 6;

pub fn init_audio_ringbuf() {
    INIT_ONCE.call_once(|| {
        let rb = HeapRb::<f32>::new(RINGBUF_CAPACITY);
        let (prod, cons) = rb.split();
        PRODUCER.set(std::sync::Mutex::new(prod)).ok();
        let leaked = Box::leak(Box::new(cons));
        CONSUMER_PTR.store(leaked as *mut HeapCons<f32>, Ordering::Release);
        // 初始化全局 DSP 管线（实时播放路径使用）
        crate::api::dsp::dsp_global_init();
    });
}

/// 读取当前频谱（16 频段，0~1）
pub fn get_spectrum() -> Vec<f32> {
    SPECTRUM.lock().map(|g| g.to_vec()).unwrap_or_default()
}

/// 读取 underrun 计数
pub fn get_underrun_count() -> u64 {
    UNDERRUN_COUNT.load(Ordering::Acquire)
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

    // 频谱 FFT 状态（realfft 每帧复用）
    let mut planner = realfft::RealFftPlanner::<f32>::new();
    let fft_len = 1024usize; // 取帧的前 1024 样本做频谱
    let r2c = planner.plan_fft_forward(fft_len);
    let mut spectrum_buf = vec![Complex::<f32>::new(0.0, 0.0); fft_len / 2 + 1];
    let mut input_scratch = vec![0.0f32; fft_len];

    loop {
        if DECODER_GEN.load(Ordering::Acquire) != gen { break; }
        match rx.recv_timeout(std::time::Duration::from_millis(500)) {
            Ok(frame) => {
                let mut s = frame.samples;

                // 1) 实时 DSP（EQ/串扰/展宽/限幅/抖动）— 在推入 ringbuf 前处理
                crate::api::dsp::dsp_global_process(&mut s);

                // 2) 计算频谱（取前 fft_len 个样本，单声道降混）
                compute_spectrum(&s, fft_len, &r2c, &mut input_scratch, &mut spectrum_buf);

                // 3) 必须把整帧（可能 > ringbuf 剩余空间）全部写入，
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

/// 计算 16 频段频谱能量（对数频段划分），结果平滑写入 SPECTRUM
fn compute_spectrum(
    samples: &[f32],
    fft_len: usize,
    r2c: &std::sync::Arc<dyn realfft::RealToComplex<f32>>,
    input_scratch: &mut [f32],
    spectrum_buf: &mut [realfft::num_complex::Complex<f32>],
) {
    if samples.len() < fft_len {
        return;
    }
    // 取左声道（交错：偶数索引）前 fft_len 个样本
    for i in 0..fft_len {
        input_scratch[i] = samples[i * 2];
    }
    // 加 Hann 窗减少频谱泄漏
    for i in 0..fft_len {
        let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / (fft_len as f32 - 1.0)).cos();
        input_scratch[i] *= w;
    }
    if r2c.process(input_scratch, spectrum_buf).is_err() {
        return;
    }
    // 频段边界（对数划分，覆盖 ~20Hz ~ 20kHz）
    let sr = 44100.0f32;
    let bin_hz = sr / fft_len as f32;
    let mut energies = [0.0f32; SPECTRUM_BANDS];
    let mut prev_hz = 20.0f32;
    for b in 0..SPECTRUM_BANDS {
        let next_hz = 20.0 * (1000.0f32).powf((b as f32 + 1.0) / SPECTRUM_BANDS as f32);
        let lo = (prev_hz / bin_hz).floor().max(1.0) as usize;
        let hi = ((next_hz / bin_hz).ceil() as usize).min(spectrum_buf.len() - 1);
        let mut e = 0.0f32;
        for k in lo..=hi {
            let re = spectrum_buf[k].re;
            e += re * re;
        }
        let n = (hi - lo + 1).max(1) as f32;
        energies[b] = (e / n).sqrt();
        prev_hz = next_hz;
    }
    // 归一化到 0~1（用经验缩放），并做时间平滑避免抖动
    if let Ok(mut g) = SPECTRUM.lock() {
        for b in 0..SPECTRUM_BANDS {
            let v = (energies[b] * 0.02).clamp(0.0, 1.0);
            // 上升快、下降慢
            g[b] = if v > g[b] { v } else { g[b] * 0.8 + v * 0.2 };
        }
    }
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
pub(crate) extern "C" fn audio_output_clear_ringbuf() {
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
    // 支持任意 frameCount：循环拉取，避免大帧（>1024）时后半段被静音截断
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
        // 本批不足（ringbuf 空）→ 剩余补静音，并标记 underrun
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
    use crate::api::dsp::{dsp_global_apply_preset, dsp_global_init, dsp_global_process, EqPreset};

    #[test]
    fn dsp_path_applies_and_spectrum_computes() {
        // 1) EQ 预设确实改变样本（证明 DSP 已接入播放路径，而非死代码）
        dsp_global_init();
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

        // 2) underrun 初始为 0
        assert_eq!(get_underrun_count(), 0);

        // 3) 频谱在 run_decoder 运行后非零
        init_audio_ringbuf();
        start_file_decoder(
            "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a".to_string(),
            None,
        );
        std::thread::sleep(std::time::Duration::from_millis(2500));
        let spec = get_spectrum();
        let spec_sum: f32 = spec.iter().sum();
        assert_eq!(spec.len(), 16, "频谱应为 16 段");
        assert!(spec_sum > 0.001, "频谱全零，未在计算，spec={spec_sum:.4}");
        stop_file_decoder();
    }
}


