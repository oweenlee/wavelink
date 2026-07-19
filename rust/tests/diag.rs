//! 真实测量：在 macOS 用 Rust 层直接模拟 iOS 的 AVAudioSourceNode 持续拉取场景，
//! 检测 PCM 连续性（磁带滑/跳变）、卡顿（缓冲区抽干）、切歌残留。
//!
//! 关键修复：单个 decoder 持续跑到结束，不再中途 stop。这样才能真正测出
//! "稳态播放时 ringbuf 是否被抽干 / 是否有跳变"。
//!
//! 运行：cargo test --test diag -- --nocapture
use rust_lib_wavelink_mobile::audio_output::{
    audio_output_fill_buffer_stereo, debug_occupied, init_audio_ringbuf, start_file_decoder,
    stop_file_decoder,
};

const FILE: &str = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";

/// 拉一批帧，返回 (非静音样本数, 峰值, 总样本数)
fn pull() -> (usize, f32, usize) {
    let mut left = [0.0f32; 2048];
    let mut right = [0.0f32; 2048];
    unsafe {
        audio_output_fill_buffer_stereo(left.as_mut_ptr(), right.as_mut_ptr(), 1024);
    }
    let v: Vec<f32> = left.iter().chain(right.iter()).copied().collect();
    let nonzero = v.iter().filter(|&&x| x.abs() > 1e-3).count();
    let peak = v.iter().map(|&x| x.abs()).fold(0.0f32, f32::max);
    (nonzero, peak, v.len())
}

#[test]
fn diag_audio_pipeline() {
    init_audio_ringbuf();

    // ── 阶段 1：单个 decoder 持续跑到底，测稳态连续性 ──
    start_file_decoder(FILE.to_string(), None);
    std::thread::sleep(std::time::Duration::from_millis(2000));

    let mut silent_runs = 0usize;
    let mut total_pulls = 0usize;
    let mut max_peak = 0.0f32;
    let mut min_occ_when_audio_expected = usize::MAX;
    let mut prev_peak = 0.0f32;
    let mut big_jumps = 0usize;
    let start = std::time::Instant::now();

    // 拉满 12 秒（歌曲前奏静音较多，需足够时长才能进入人声段）
    while start.elapsed() < std::time::Duration::from_secs(12) {
        let (nz, pk, _) = pull();
        let occ = debug_occupied();
        total_pulls += 1;
        if nz == 0 {
            silent_runs += 1;
        } else {
            max_peak = max_peak.max(pk);
            // 期望有声音时，ringbuf 不应被抽干到接近 0
            min_occ_when_audio_expected = min_occ_when_audio_expected.min(occ);
        }
        // 相邻峰值骤降（从有声突然掉到极小）可能是缓冲区抽干/跳变
        if prev_peak > 0.05 && pk < prev_peak * 0.05 {
            big_jumps += 1;
        }
        prev_peak = pk;
        if total_pulls < 10 || total_pulls % 50 == 0 {
            eprintln!(
                "[OCC] pull#{total_pulls} nonzero={nz} peak={pk:.4} occupied={occ}"
            );
        }
        std::thread::sleep(std::time::Duration::from_millis(23));
    }
    eprintln!(
        "[MEASURE] 阶段1 连续拉取 {total_pulls} 次, 全静音={silent_runs}, 峰值骤降={big_jumps}, 最大峰值={max_peak:.4}, 有声时最小occupied={min_occ_when_audio_expected}"
    );
    stop_file_decoder();
    std::thread::sleep(std::time::Duration::from_millis(300));

    // ── 阶段 2：切歌后 ringbuf 应清空，无残留串音 ──
    start_file_decoder(FILE.to_string(), None);
    std::thread::sleep(std::time::Duration::from_millis(1500));
    for _ in 0..5 {
        pull();
    }
    stop_file_decoder();
    std::thread::sleep(std::time::Duration::from_millis(300));
    let (nz_after, pk_after, _) = pull();
    eprintln!("[MEASURE] 阶段2 stop 后拉取: 非静音={nz_after}, 峰值={pk_after:.4}");
    assert!(
        nz_after == 0,
        "stop 后 ringbuf 未清空，残留 {nz_after} 样本（切歌串音）"
    );
}
