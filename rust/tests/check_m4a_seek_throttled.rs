//! 模拟"节流后的快速拖动"：每 60ms 产生一次 seek 请求，但合并为 120ms 执行一次最新目标
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use rust_lib_wavelink_mobile::audio_output::{init_audio_ringbuf, start_file_decoder, stop_file_decoder};
use rust_lib_wavelink_mobile::ffi::audio_output_fill_buffer_stereo;

#[test]
fn m4a_throttled_seek_stalls() {
    let path = "/Users/qin/Desktop/demos/a_music/李荣浩-恋人.m4a";
    if !std::path::Path::new(path).exists() { eprintln!("缺失"); return; }
    init_audio_ringbuf();

    let consumed = Arc::new(std::sync::Mutex::new(Vec::<f32>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let stop_c = stop.clone();
    let consumed_c = consumed.clone();
    let cons = thread::spawn(move || {
        let mut left = [0.0f32; 2048];
        let mut right = [0.0f32; 2048];
        while !stop_c.load(Ordering::Acquire) {
            unsafe { audio_output_fill_buffer_stereo(left.as_mut_ptr(), right.as_mut_ptr(), 1024); }
            let mut buf = consumed_c.lock().unwrap();
            for i in 0..1024 { buf.push(left[i]); buf.push(right[i]); }
            drop(buf);
            thread::sleep(Duration::from_millis(10));
        }
    });

    start_file_decoder(path.to_string(), None);
    thread::sleep(Duration::from_millis(500));

    // 模拟节流：每 60ms 记一次目标，但每 120ms 才真正执行一次最新目标
    let mut t = 5.0f64;
    let mut seed: u64 = 12345;
    let mut pending: Option<f64> = None;
    for _ in 0..80 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        t += 3.0 + (seed % 7) as f64;
        if t > 270.0 { t = 5.0; }
        pending = Some(t); // 合并请求
        if (_tick(&mut 0) % 2) == 0 {
            // 每两次(120ms)执行一次
            stop_file_decoder();
            start_file_decoder(path.to_string(), pending);
            pending = None;
        }
        thread::sleep(Duration::from_millis(60));
    }
    if pending.is_some() { stop_file_decoder(); start_file_decoder(path.to_string(), pending); }
    thread::sleep(Duration::from_millis(1500));
    stop.store(true, Ordering::Release);
    cons.join().unwrap();

    let buf = consumed.lock().unwrap();
    let n = buf.len() / 2;
    let mut silent_run = 0usize;
    let mut silent_total = 0usize;
    let mut silent_max = 0usize;
    let mut silent_segments = 0usize;
    for f in 0..n {
        let m = buf[f*2].abs().max(buf[f*2+1].abs());
        if m < 1e-3 {
            if silent_run == 0 { silent_segments += 1; }
            silent_run += 1; silent_total += 1;
            if silent_run > silent_max { silent_max = silent_run; }
        } else { silent_run = 0; }
    }
    drop(buf);
    eprintln!("[节流后] 总帧 {n}，静音补零帧 {silent_total} ({:.2}%)，断流段数 {silent_segments}，最长断流 {:.1}ms",
        silent_total as f64/n as f64*100.0, silent_max as f64/44100.0*1000.0);
}
fn _tick(x: &mut u32) -> u32 { *x += 1; *x }
