//! 回归测试：本地文件被删除/移动后再播放，引擎必须干净收敛
//!
//! 真实 bug 场景：用户在文件管理器中移动/改名了音乐文件，播放器里
//! 再次播放该条目。修复前引擎状态机卡死——playing 永远为 true、
//! position 超出时长、underrun 持续飙升、残留预加载帧被播出（听感沙沙声）。
//!
//! 修复点（两处，缺一不可）：
//! 1. stop_playback 清除 next_rx 残留预加载接收端
//! 2. advance_normal/advance_shuffle 队列空时彻底 stop_playback + 位置归零

use std::time::{Duration, Instant};

use audio_core::engine::{EngineEvent, EngineHandle};
use audio_core::EngineConfig;

/// 生成短促恒定电平 WAV
fn write_wav(path: &str, value: f32, duration_secs: f64) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44100,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    let frames = (44100.0 * duration_secs) as usize;
    let v = (value * 32767.0) as i16;
    for _ in 0..frames {
        w.write_sample(v).unwrap();
        w.write_sample(v).unwrap();
    }
    w.finalize().unwrap();
}

fn wait_for_playing(handle: &EngineHandle, expected: bool, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if handle.is_playing() == expected {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    handle.is_playing() == expected
}

#[test]
fn missing_file_then_replay_converges_cleanly() {
    let dir = std::env::temp_dir();
    let a = format!("{}/wavelink_missing_a.wav", dir.display());
    let a_moved = format!("{}/wavelink_missing_a_moved.wav", dir.display());
    let b = format!("{}/wavelink_missing_b.wav", dir.display());
    let _ = std::fs::remove_file(&a_moved);
    write_wav(&a, 0.3, 0.2);
    write_wav(&b, -0.3, 0.2);

    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    // 第一轮：正常播放，建立预加载状态
    handle.play_queue(vec![a.clone(), b.clone()]);
    assert!(wait_for_playing(&handle, true, Duration::from_secs(5)), "首轮应开始播放");
    // 等第一轮播完（两首共 0.4s + 余量）
    assert!(wait_for_playing(&handle, false, Duration::from_secs(10)), "首轮应自然播完");

    // 模拟用户删除/移动文件 A
    std::fs::rename(&a, &a_moved).expect("改名模拟删除失败");

    // 第二轮：再播含已失效路径的队列
    handle.play_queue(vec![a.clone(), b.clone()]);

    // 期望：A 报错跳过，B 正常播放，最终干净停止
    let mut got_b = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(EngineEvent::TrackChanged(p)) if p == b => got_b = true,
            Ok(EngineEvent::PlaybackStopped) if got_b => break,
            Ok(_) => {}
            Err(_) => {}
        }
    }
    assert!(got_b, "失效文件应被跳过并播放 B");
    assert!(wait_for_playing(&handle, false, Duration::from_secs(5)), "播完后 playing 必须为 false");
    assert!(handle.position_secs() < 0.05, "停止后位置应归零，实际 {}", handle.position_secs());

    // underrun 不应持续增长（状态机卡死的标志）
    let u1 = handle.underrun_count();
    std::thread::sleep(Duration::from_millis(300));
    let u2 = handle.underrun_count();
    assert!(u2.saturating_sub(u1) <= 2, "停止后 underrun 不应持续增长: {u1} -> {u2}");

    let _ = std::fs::remove_file(&a_moved);
    let _ = std::fs::remove_file(&b);
}
