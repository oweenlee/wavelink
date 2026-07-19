//! 复现并验证 iOS "磁带滑/跳播" 的成因与修复。
//!
//! 成因：iOS 上 AVAudioSourceNode 在 engine.pause() 后回调停摆，但 Rust 解码线程
//! 仍在往 ringbuf 推数据。恢复播放时，sourceNode 把暂停期间积压的数据一次性吐出，
//! 表现为"歌曲快进/重复 = 磁带滑"。
//!
//! 本测试在 macOS 用 Rust 层模拟该语义：
//!   - 暂停 = consumer 停止调用 fill_buffer（引擎不拉数据），producer 继续推
//!   - 恢复（旧语义）= 直接继续拉：应观察到大量积压需排空 = 磁带滑
//!   - 恢复（新语义）= 先 audio_output_clear_ringbuf() 再拉：积压被丢弃，无缝接实时
//!
//! 运行：cargo test --test repro_pause_slip -- --nocapture
use rust_lib_wavelink_mobile::audio_output::{
    audio_output_clear_ringbuf, audio_output_fill_buffer_stereo, debug_occupied,
    init_audio_ringbuf, start_file_decoder, stop_file_decoder,
};

const FILE: &str = "/Users/qin/Desktop/demos/a_music/梁博-出现又离开.m4a";

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
fn repro_pause_then_resume_without_clear() {
    init_audio_ringbuf();
    start_file_decoder(FILE.to_string(), None);
    // 稳定拉 2 秒建立基线
    std::thread::sleep(std::time::Duration::from_millis(2000));
    for _ in 0..20 {
        pull();
        std::thread::sleep(std::time::Duration::from_millis(23));
    }

    // ── 模拟暂停 3 秒：consumer 完全停拉，producer 继续推 ──
    std::thread::sleep(std::time::Duration::from_millis(3000));
    let occ_after_pause = debug_occupied();

    // ── 恢复（旧语义：不清 ringbuf，直接继续拉）──
    // 观察：需要拉多久才重新进入"实时"——这段追赶时间就是磁带滑时长
    let mut drain = 0usize;
    let mut fresh = false;
    let start = std::time::Instant::now();
    while start.elapsed() < std::time::Duration::from_secs(6) {
        let (_, _, _) = pull();
        drain += 1;
        let occ = debug_occupied();
        // 当 occupied 从接近满（积压）降到 streaming 稳态（大幅低于满）即认为追上实时
        if occ < occ_after_pause / 2 {
            fresh = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(23));
    }
    let drain_ms = drain as u64 * 23;
    eprintln!(
        "[MEASURE] 旧语义 暂停后 ringbuf 积压={occ_after_pause}, 恢复后追赶耗时≈{drain_ms}ms, 是否追上实时={fresh}"
    );
    stop_file_decoder();
    std::thread::sleep(std::time::Duration::from_millis(300));
    // 旧语义下必然存在明显追赶（积压未被丢弃）→ 这就是磁带滑
    assert!(
        occ_after_pause > 100_000,
        "暂停期间应产生积压，但实际积压={occ_after_pause}"
    );
    assert!(
        drain_ms > 1000,
        "旧语义恢复应出现明显追赶（磁带滑），但仅 {drain_ms}ms"
    );
}

#[test]
fn repro_pause_then_resume_with_clear() {
    init_audio_ringbuf();
    start_file_decoder(FILE.to_string(), None);
    std::thread::sleep(std::time::Duration::from_millis(2000));
    for _ in 0..20 {
        pull();
        std::thread::sleep(std::time::Duration::from_millis(23));
    }

    // 模拟暂停 3 秒
    std::thread::sleep(std::time::Duration::from_millis(3000));
    let occ_after_pause = debug_occupied();

    // 恢复（新语义：先清 ringbuf 丢弃积压，再继续拉）
    audio_output_clear_ringbuf();
    let occ_after_clear = debug_occupied();

    // 继续拉，检测是否立即进入"实时"（不再有积压需要追赶）
    let mut max_occ_after_resume = 0usize;
    for _ in 0..20 {
        pull();
        let occ = debug_occupied();
        max_occ_after_resume = max_occ_after_resume.max(occ);
        std::thread::sleep(std::time::Duration::from_millis(23));
    }
    eprintln!(
        "[MEASURE] 新语义 暂停后积压={occ_after_pause}, clear后={occ_after_clear}, 恢复后最大occupied={max_occ_after_resume}"
    );
    stop_file_decoder();
    std::thread::sleep(std::time::Duration::from_millis(300));

    // 新语义：clear 后积压应立即归零，恢复后 occupied 不应再出现大积压
    assert_eq!(occ_after_clear, 0, "clear_ringbuf 应把 ringbuf 清空");
    assert!(
        max_occ_after_resume < occ_after_pause,
        "恢复后不应再有暂停期间的积压"
    );
}
