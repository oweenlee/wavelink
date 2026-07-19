//! 复现 iOS "磁带滑" 的本地（macOS）集成测试（强化并发版）。
//!
//! 模拟 AVAudioSourceNode 的连续 pull：消费者线程不停调用
//! `audio_output_fill_buffer_stereo` 拉样本。同时主线程以高频、近乎零间隔
//! 反复 stop→start 在 A/B 之间切换，模拟用户快速切歌 / seek 的并发场景。
//!
//! 检测两类缺陷：
//!   (a) 旧帧泄漏：切换后消费流里出现属于 A 的样本窗口。
//!   (b) 时间回跳：消费流里 B 的窗口集合"回退"到更早出现过的 B 窗口
//!       （说明 ringbuf 把滞后的旧 B 帧又喂了一次）。

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use rust_lib_wavelink_mobile::audio_output::{
    audio_output_fill_buffer_stereo, init_audio_ringbuf, start_file_decoder, stop_file_decoder,
};
use rust_lib_wavelink_mobile::decode::decode_file;

const WINDOW: usize = 64;

fn window_hash(w: &[f32]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &s in w {
        h ^= s.to_bits() as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 预解码文件，返回窗口 hash 集合（跳过静音/低能量窗口，避免假阳性）。
fn build_windows(path: &str) -> HashSet<u64> {
    let pcm = decode_file(path.to_string()).expect("解码失败").samples;
    let mut set = HashSet::new();
    for w in pcm.windows(WINDOW) {
        // 跳过能量过低的窗口（静音段在所有文件里都是 0.0，会互相命中）
        let energy: f32 = w.iter().map(|&s| s * s).sum();
        if energy < 1e-4 {
            continue;
        }
        set.insert(window_hash(w));
    }
    set
}

/// 判断窗口是否低能量（静音），检测时跳过。
fn is_silent(w: &[f32]) -> bool {
    let energy: f32 = w.iter().map(|&s| s * s).sum();
    energy < 1e-4
}

#[test]
fn repro_switch_stress() {
    let a_path = "/Users/qin/Desktop/demos/a_music/一千个伤心的理由.flac";
    let b_path = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";
    if !std::path::Path::new(a_path).exists() || !std::path::Path::new(b_path).exists() {
        eprintln!("测试音频文件缺失，跳过");
        return;
    }

    init_audio_ringbuf();

    let a_windows = build_windows(a_path);
    let b_windows = build_windows(b_path);
    eprintln!("A 窗口: {}, B 窗口: {}", a_windows.len(), b_windows.len());

    let consumed = Arc::new(std::sync::Mutex::new(Vec::<f32>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let stop_c = stop.clone();
    let consumed_c = consumed.clone();
    let cons = thread::spawn(move || {
        let mut left = [0.0f32; 2048];
        let mut right = [0.0f32; 2048];
        while !stop_c.load(Ordering::Acquire) {
            unsafe {
                audio_output_fill_buffer_stereo(left.as_mut_ptr(), right.as_mut_ptr(), 1024);
            }
            let mut buf = consumed_c.lock().unwrap();
            for i in 0..1024 {
                buf.push(left[i]);
                buf.push(right[i]);
            }
            drop(buf);
            thread::sleep(Duration::from_millis(10));
        }
    });

    // 高频零间隔切换
    start_file_decoder(a_path.to_string(), None);
    let mut toggle = false;
    for _ in 0..30 {
        stop_file_decoder();
        let p = if toggle { a_path } else { b_path };
        start_file_decoder(p.to_string(), None);
        toggle = !toggle;
        thread::sleep(Duration::from_millis(40));
    }
    // 最后稳定到 B
    stop_file_decoder();
    start_file_decoder(b_path.to_string(), None);
    thread::sleep(Duration::from_millis(1500));

    stop.store(true, Ordering::Release);
    cons.join().unwrap();

    let buf = consumed.lock().unwrap();
    let n = buf.len();
    eprintln!("总消费样本: {n}");

    // 检测：从消费流中点之后，统计命中 A / B 的窗口，并检查 B 是否回跳。
    let start = n / 2;
    let mut a_leaks = 0usize;
    let mut b_seen: HashSet<u64> = HashSet::new();
    let mut b_rewind = 0usize;
    for i in (start.saturating_sub(WINDOW - 1))..(n - WINDOW) {
        let w = &buf[i..i + WINDOW];
        if is_silent(w) {
            continue;
        }
        let h = window_hash(w);
        if a_windows.contains(&h) {
            a_leaks += 1;
        }
        if b_windows.contains(&h) {
            if !b_seen.insert(h) {
                b_rewind += 1; // B 窗口重复出现 = 时间回退
            }
        }
    }
    drop(buf);

    eprintln!("切歌后 A 旧帧泄漏: {a_leaks}, B 时间回退: {b_rewind}");

    assert_eq!(a_leaks, 0, "检测到旧帧(A)泄漏 —— iOS 磁带滑根因之一");
    assert_eq!(
        b_rewind, 0,
        "检测到 B 时间回退（重复窗口）—— sourceNode 拉到了滞后的旧帧"
    );
}
