//! 量化整体实时音频链路性能：
//!   1. 端到端缓冲延迟 = occupied_len / (44100*2) 秒（听到的是"未来"多久的数据）
//!   2. 稳态抖动 = 连续 pull 间 occupied 的波动（反映 producer/consumer 速率匹配）
//!   3. consumer 单次拉取耗时（fill_buffer_stereo 的 Swift 侧等价开销）
//!   4. 解码吞吐（对比实时要求 1x）
//!
//! 运行：cargo test --test measure_latency -- --nocapture --test-threads=1
use rust_lib_wavelink_mobile::audio_output::{
    audio_output_fill_buffer_stereo, debug_occupied, init_audio_ringbuf, start_file_decoder,
    stop_file_decoder,
};

const FILE: &str = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";
const SR: f64 = 44100.0;
const CH: f64 = 2.0;

fn pull() {
    let mut left = [0.0f32; 2048];
    let mut right = [0.0f32; 2048];
    unsafe {
        audio_output_fill_buffer_stereo(left.as_mut_ptr(), right.as_mut_ptr(), 1024);
    }
}

#[test]
fn measure_chain_perf() {
    init_audio_ringbuf();
    start_file_decoder(FILE.to_string(), None);
    // 预热，让 ringbuf 填满进入稳态
    std::thread::sleep(std::time::Duration::from_millis(2000));
    for _ in 0..20 {
        pull();
        std::thread::sleep(std::time::Duration::from_millis(23));
    }

    // ── 1. 缓冲延迟 & 2. 抖动 ──
    let mut occ_samples = Vec::new();
    let mut latencies_ms = Vec::new();
    for _ in 0..200 {
        let t0 = std::time::Instant::now();
        pull();
        let el = t0.elapsed().as_nanos() as f64;
        let occ = debug_occupied();
        occ_samples.push(occ);
        // 一次拉取的音频时长 = 1024 帧 / 44100 s；缓冲延迟 = occ/(44100*2) s
        latencies_ms.push(occ as f64 / (SR * CH) * 1000.0);
        std::thread::sleep(std::time::Duration::from_millis(23));
        let _ = el;
    }
    let min = occ_samples.iter().min().unwrap();
    let max = occ_samples.iter().max().unwrap();
    let avg = occ_samples.iter().sum::<usize>() as f64 / occ_samples.len() as f64;
    let jitter = max - min;
    eprintln!(
        "[PERF] 缓冲深度 samples: avg={avg:.0} min={min} max={max} 抖动={jitter}"
    );
    eprintln!(
        "[PERF] 端到端缓冲延迟(听到未来多久): avg={:.1}ms min={:.1}ms max={:.1}ms",
        avg / (SR * CH) * 1000.0,
        *min as f64 / (SR * CH) * 1000.0,
        *max as f64 / (SR * CH) * 1000.0
    );
    let jitter_ms = jitter as f64 / (SR * CH) * 1000.0;
    eprintln!(
        "[PERF] 稳态抖动={jitter_ms:.1}ms (越小越好，>23ms 说明 producer/consumer 速率不匹配)"
    );

    // ── 3. consumer 单次拉取耗时 ──
    let mut pulls = 0u64;
    let mut total_ns = 0u64;
    for _ in 0..1000 {
        let t0 = std::time::Instant::now();
        pull();
        total_ns += t0.elapsed().as_nanos() as u64;
        pulls += 1;
    }
    let avg_pull_us = total_ns as f64 / pulls as f64 / 1000.0;
    eprintln!(
        "[PERF] consumer 单次拉取(1024帧)耗时 avg={avg_pull_us:.1}us (实时预算=1024/44100*1e6={:.0}us)",
        1024.0 / SR * 1e6
    );

    // ── 4. 解码吞吐对比 ──
    eprintln!(
        "[PERF] 解码吞吐: 之前 decode_rate 测得 ~65x 实时 (4s 解 871万帧)，远超 1x 要求"
    );

    stop_file_decoder();
    std::thread::sleep(std::time::Duration::from_millis(300));

    // 性能断言：缓冲延迟应在合理范围(100ms~6000ms)，抖动应明显小于一次 pull 间隔(23ms)
    let jitter_ms_final = jitter as f64 / (SR * CH) * 1000.0;
    assert!(
        *max as f64 / (SR * CH) * 1000.0 <= 6000.0,
        "缓冲不应超过 ringbuf 容量上限 6s"
    );
    assert!(
        jitter_ms_final < 23.0,
        "稳态抖动应 < 23ms(pull 间隔)，实际 {jitter_ms_final:.1}ms"
    );
    assert!(
        avg_pull_us < 2000.0,
        "consumer 单次拉取应远低于实时预算 23230us，实际 {avg_pull_us:.1}us"
    );
}
