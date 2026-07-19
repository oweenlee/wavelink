//! 检测"持续播放"是否有 underrun（消费流静音段）= 真实卡音
//! 消费者严格按实时速率(44100/s)拉取，模拟 AVAudioSourceNode
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use rust_lib_wavelink_mobile::audio_output::{
    audio_output_fill_buffer_stereo, init_audio_ringbuf, start_file_decoder,
};

fn run(path: &str, label: &str) {
    if !std::path::Path::new(path).exists() { eprintln!("{label}: 文件缺失"); return; }
    init_audio_ringbuf();
    let consumed = Arc::new(std::sync::Mutex::new(Vec::<f32>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let stop_c = stop.clone();
    let consumed_c = consumed.clone();
    let cons = thread::spawn(move || {
        let mut left = [0.0f32; 2048];
        let mut right = [0.0f32; 2048];
        let frame_ms = 1024.0 / 44100.0 * 1000.0; // 23.2ms
        let mut next = Instant::now();
        while !stop_c.load(Ordering::Acquire) {
            unsafe { audio_output_fill_buffer_stereo(left.as_mut_ptr(), right.as_mut_ptr(), 1024); }
            let mut buf = consumed_c.lock().unwrap();
            for i in 0..1024 { buf.push(left[i]); buf.push(right[i]); }
            drop(buf);
            next += Duration::from_secs_f64(frame_ms / 1000.0);
            let now = Instant::now();
            if next > now { thread::sleep(next - now); }
            else { next = now; } // 落后则立即追（放宽，避免测试自身瓶颈）
        }
    });

    start_file_decoder(path.to_string(), None);
    // 播放 20 秒
    thread::sleep(Duration::from_millis(20000));
    stop.store(true, Ordering::Release);
    cons.join().unwrap();

    let buf = consumed.lock().unwrap();
    let n = buf.len() / 2;
    let mut silent_run = 0usize;
    let mut silent_total = 0usize;
    let mut silent_max = 0usize;
    let mut segments = 0usize;
    let mut max_gap_ms = 0.0f64;
    let mut last_audio = 0usize;
    for f in 0..n {
        let m = buf[f*2].abs().max(buf[f*2+1].abs());
        if m < 1e-3 {
            if silent_run == 0 { segments += 1; if f > 0 { let g = (f - last_audio) as f64/44100.0*1000.0; if g > max_gap_ms { max_gap_ms = g; } } }
            silent_run += 1; silent_total += 1;
            if silent_run > silent_max { silent_max = silent_run; }
        } else { last_audio = f; silent_run = 0; }
    }
    drop(buf);
    eprintln!("[{label}] 播放20s: 总帧 {n}, 静音 {silent_total}({:.2}%), 段数 {segments}, 最长静音 {:.1}ms, 最大音频间隙 {:.1}ms",
        silent_total as f64/n as f64*100.0, silent_max as f64/44100.0*1000.0, max_gap_ms);
}

#[test]
fn underrun_flac() {
    run("/Users/qin/Desktop/demos/a_music/一千个伤心的理由.flac", "FLAC");
}
#[test]
fn underrun_m4a() {
    run("/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a", "M4A");
}
#[test]
fn underrun_mp3() {
    run("/Users/qin/Desktop/demos/a_music/蔡琴《渡口》.mp3", "MP3");
}
