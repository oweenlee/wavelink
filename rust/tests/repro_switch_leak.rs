//! 复现 iOS "磁带滑" 的本地（macOS）集成测试。
//!
//! 模拟 AVAudioSourceNode 的连续 pull 行为：消费者线程不停调用
//! `audio_output_fill_buffer_stereo` 拉取样本，生产者是 `run_decoder` 线程
//! 持续 push。在播放中途执行 stop(A) + 立即 start(B)，检测切换之后
//! 消费流里是否混入属于 A 的样本（旧帧泄漏 = 磁带滑根因）。
//!
//! 机制：预解码 A 得到全量 PCM，切成固定窗口并建 hash 集合；切换后
//! 在消费流上滑动窗口，若命中 A 的窗口集合即判定旧帧泄漏。

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use rust_lib_wavelink_mobile::audio_output::{
    audio_output_fill_buffer_stereo, init_audio_ringbuf, start_file_decoder, stop_file_decoder,
};
use rust_lib_wavelink_mobile::decode::decode_file;

const WINDOW: usize = 64; // 窗口样本数（交错，含双声道）

fn window_hash(w: &[f32]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &s in w {
        let bits = s.to_bits() as u64;
        h ^= bits;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 预解码文件，返回全量交错 f32 PCM 与窗口 hash 集合。
fn build_pcm_windows(path: &str) -> (Vec<f32>, HashSet<u64>) {
    let pcm = decode_file(path.to_string())
        .expect("解码失败")
        .samples;
    let mut set = HashSet::new();
    for w in pcm.windows(WINDOW) {
        set.insert(window_hash(w));
    }
    (pcm, set)
}

/// 消费者：持续 pull，把拉到的样本追加到 out，返回拉取总数。
fn consumer_loop(stop: Arc<AtomicBool>, out: Arc<std::sync::Mutex<Vec<f32>>>) {
    let mut left = [0.0f32; 2048];
    let mut right = [0.0f32; 2048];
    while !stop.load(Ordering::Acquire) {
        unsafe {
            audio_output_fill_buffer_stereo(left.as_mut_ptr(), right.as_mut_ptr(), 1024);
        }
        let mut buf = out.lock().unwrap();
        for i in 0..1024 {
            buf.push(left[i]);
            buf.push(right[i]);
        }
        drop(buf);
        // 模拟 sourceNode 的实时节奏（1024 帧 ≈ 23ms）
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn repro_switch_leaks_old_frames() {
    let a_path = "/Users/qin/Desktop/demos/a_music/一千个伤心的理由.flac";
    let b_path = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";

    if !std::path::Path::new(a_path).exists() || !std::path::Path::new(b_path).exists() {
        eprintln!("测试音频文件缺失，跳过");
        return;
    }

    init_audio_ringbuf();

    // 预解码 A，建立窗口集合
    let (_a_pcm, a_windows) = build_pcm_windows(a_path);
    eprintln!("A 窗口集合大小: {}", a_windows.len());

    let consumed = Arc::new(std::sync::Mutex::new(Vec::<f32>::new()));
    let stop = Arc::new(AtomicBool::new(false));

    // 启动消费者（模拟 sourceNode 连续 pull，先于解码启动）
    let stop_c = stop.clone();
    let consumed_c = consumed.clone();
    let cons = thread::spawn(move || consumer_loop(stop_c, consumed_c));

    // 1) 开始播放 A
    start_file_decoder(a_path.to_string(), None);

    // 让 A 持续解码一会儿（保证 ringbuf 里有 A 内容且消费者在拉）
    thread::sleep(Duration::from_millis(800));

    // 2) 模拟快速切歌：stop(A) 立即 start(B)
    let t_switch = Instant::now();
    stop_file_decoder();
    start_file_decoder(b_path.to_string(), None);

    // 继续消费足够长时间，确保 B 已被拉取
    thread::sleep(Duration::from_millis(1500));

    stop.store(true, Ordering::Release);
    cons.join().unwrap();

    let total = consumed.lock().unwrap().len();
    eprintln!("总消费样本: {total}");

    // 3) 在切换时间点之后检测 A 窗口泄漏。
    //    消费率约 1024 帧/20ms，但生产者 throttle；保守起见，
    //    只检查切换后"明显属于 B 区段"的样本窗口（跳过前一段缓冲）。
    //    更准确：从消费流中点之后开始检测，避免把切换前正常的 A 算作泄漏。
    let buf = consumed.lock().unwrap();
    let n = buf.len();
    // 跳过前 40%（切换前 + 缓冲过渡），只检测 B 稳定区段
    let start_idx = (n / 2) - (WINDOW - 1);
    let mut leaks = 0usize;
    for i in (start_idx.max(0))..(n - WINDOW) {
        let w = &buf[i..i + WINDOW];
        if a_windows.contains(&window_hash(w)) {
            leaks += 1;
        }
    }
    drop(buf);

    eprintln!("切歌后检测到 A 窗口泄漏次数: {leaks}（耗时 {:?}）", t_switch.elapsed());

    assert_eq!(
        leaks, 0,
        "检测到旧帧(A)泄漏到切歌后的消费流中 —— 这是 iOS 磁带滑的根因"
    );
}
