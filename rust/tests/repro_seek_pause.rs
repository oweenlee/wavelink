//! 复现 iOS seek 时的磁带滑：模拟 `_restartStreamFrom` 的 Swift pause 语义。
//!
//! AVAudioEngine.pause() 会暂停 sourceNode 回调（消费者停拉），但 Rust 解码
//! 线程不停、继续往 ringbuf 推。若 pause 期间 ringbuf 堆积了旧帧，resume 后
//! sourceNode 从堆积位置消费，就会听到"时间回退"= 磁带滑。
//!
//! 本测试精确模拟该调用序列，并用 B_pcm 的绝对位置比对检测消费流是否回退。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
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

fn is_silent(w: &[f32]) -> bool {
    let energy: f32 = w.iter().map(|&s| s * s).sum();
    energy < 1e-4
}

/// 构建窗口→在 B_pcm 中首次出现位置的映射（用于检测时间回退）。
fn build_position_map(pcm: &[f32]) -> HashMap<u64, usize> {
    let mut m = HashMap::new();
    for (i, w) in pcm.windows(WINDOW).enumerate() {
        if is_silent(w) {
            continue;
        }
        let h = window_hash(w);
        m.entry(h).or_insert(i);
    }
    m
}

#[test]
fn repro_seek_pause_rewind() {
    let b_path = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";
    if !std::path::Path::new(b_path).exists() {
        eprintln!("测试音频文件缺失，跳过");
        return;
    }
    init_audio_ringbuf();

    let b_pcm = decode_file(b_path.to_string()).expect("解码失败").samples;
    let pos_map = build_position_map(&b_pcm);
    eprintln!("B 非静音窗口数: {}", pos_map.len());

    // 共享状态
    let consumed = Arc::new(Mutex::new(Vec::<f32>::new()));
    let paused = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));

    let paused_c = paused.clone();
    let stop_c = stop.clone();
    let consumed_c = consumed.clone();
    let cons = thread::spawn(move || {
        let mut left = [0.0f32; 2048];
        let mut right = [0.0f32; 2048];
        while !stop_c.load(Ordering::Acquire) {
            if paused_c.load(Ordering::Acquire) {
                thread::sleep(Duration::from_millis(5));
                continue;
            }
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

    // 1) 开始播放 B（模拟 play）
    start_file_decoder(b_path.to_string(), None);
    thread::sleep(Duration::from_millis(500));

    // 2) 模拟 Dart pause()：只让消费者停拉，但【没调 stopDecoder】
    //    producer 持续推，超过 ringbuf 容量(6s)后环绕覆盖未消费数据
    paused.store(true, Ordering::Release);
    thread::sleep(Duration::from_millis(7000)); // > 6s 容量，触发环绕覆盖

    // 3) 模拟 Dart resume()：消费者恢复，但没重新 startDecoder
    paused.store(false, Ordering::Release);
    thread::sleep(Duration::from_millis(1500));

    stop.store(true, Ordering::Release);
    cons.join().unwrap();

    // 分析消费流：检测 resume 之后是否出现 B 绝对位置回退
    let buf = consumed.lock().unwrap();
    let n = buf.len();
    // 找 resume 对应的消费流位置：resume 前 paused 约 1600ms，消费流前段是正常播放
    // 取后 60% 作为 resume 后区段
    let start = (n as f64 * 0.5) as usize;

    let mut prev_pos: Option<usize> = None;
    let mut rewind_events = 0usize;
    let mut consecutive_down = 0usize;
    for i in (start.saturating_sub(WINDOW - 1))..(n - WINDOW) {
        let w = &buf[i..i + WINDOW];
        if is_silent(w) {
            continue;
        }
        let h = window_hash(w);
        if let Some(&p) = pos_map.get(&h) {
            if let Some(pp) = prev_pos {
                if p < pp && (pp - p) > WINDOW * 4 {
                    consecutive_down += 1;
                    if consecutive_down >= 3 {
                        rewind_events += 1;
                        consecutive_down = 0;
                    }
                } else {
                    consecutive_down = 0;
                }
            }
            prev_pos = Some(p);
        }
    }
    drop(buf);

    eprintln!("检测到 B 时间回退事件: {rewind_events}");
    assert_eq!(
        rewind_events, 0,
        "seek 后消费流出现时间回退（磁带滑）—— pause 期间 ringbuf 堆积旧帧"
    );
}
