//! 引擎端到端集成测试
//!
//! 测试 EngineHandle → 引擎线程 → 解码器 → consumer → output 完整链路。
//! 使用 HeadlessOutput（无物理设备依赖），通过合成 WAV 验证行为正确性。

use std::time::Duration;

use audio_core::engine::{EngineEvent, EngineHandle};
use audio_core::EngineConfig;
use crossbeam_channel::Receiver;

// ── 测试夹具 ──

/// 生成一个 1s 440Hz 正弦波 WAV 文件
fn generate_wav(path: &str, sample_rate: u32, channels: u16, duration_secs: f64) {
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let n = (sample_rate as f64 * duration_secs) as u32 * channels as u32;
    for i in 0..n {
        let t = i as f64 / sample_rate as f64;
        let s = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.5;
        writer.write_sample((s * i16::MAX as f64) as i16).unwrap();
    }
    writer.finalize().unwrap();
}

fn ensure_test_wav() -> String {
    let path = "/tmp/_engine_test_tone.wav".to_string();
    if !std::path::Path::new(&path).exists() {
        generate_wav(&path, 44100, 2, 1.0);
    }
    path
}

fn ensure_short_wav() -> String {
    let path = "/tmp/_engine_test_short.wav".to_string();
    if !std::path::Path::new(&path).exists() {
        generate_wav(&path, 44100, 2, 0.3);
    }
    path
}

/// 收集一段时间内的引擎事件
fn collect_events(rx: &Receiver<EngineEvent>, timeout: Duration) -> Vec<EngineEvent> {
    let deadline = std::time::Instant::now() + timeout;
    let mut events = Vec::new();
    while std::time::Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(20)) {
            Ok(ev) => events.push(ev),
            Err(_) => continue, // 超时继续，直到 deadline
        }
    }
    events
}

/// 清空事件 channel 中残留的事件
fn drain_events(rx: &Receiver<EngineEvent>) {
    loop {
        match rx.try_recv() {
            Ok(_) => continue,
            Err(_) => break,
        }
    }
}

// ── 测试 ──

#[test]
fn test_engine_play_emits_track_changed() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    handle.play(path.clone());

    let ev = rx.recv_timeout(Duration::from_secs(5))
        .expect("应收到 TrackChanged 事件");
    match ev {
        EngineEvent::TrackChanged(ref p) => assert_eq!(p, &path, "路径应匹配"),
        other => panic!("期望 TrackChanged, 收到: {other:?}"),
    }

    handle.stop();
    // 等待引擎线程退出
    std::thread::sleep(Duration::from_millis(100));
}

#[test]
fn test_engine_pause_resume_toggles_playing() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");

    assert!(handle.is_playing(), "播放后应处于播放状态");

    handle.pause();
    std::thread::sleep(Duration::from_millis(200));
    assert!(!handle.is_playing(), "暂停后应停止");

    handle.resume();
    std::thread::sleep(Duration::from_millis(200));
    assert!(handle.is_playing(), "恢复后应继续");

    handle.stop();
}

#[test]
fn test_engine_seek_changes_position() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");

    let pos_before = handle.position_secs();

    handle.seek(0.5);
    // 等待 seek 命令被引擎线程处理 + 解码器在新位置开始输出
    std::thread::sleep(Duration::from_millis(200));

    let pos_after = handle.position_secs();
    // seek 后位置应明显不同于 seek 前，且在 0.5s 附近
    assert!(
        (pos_after - pos_before).abs() > 0.1,
        "seek 后位置应显著变化: {pos_before:.3}s -> {pos_after:.3}s"
    );
    assert!(
        pos_after > 0.3,
        "seek(0.5) 后位置应在 ~0.5s, 实际: {pos_after:.3}s"
    );

    handle.stop();
}

#[test]
fn test_engine_position_increases_monotonically() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");

    let mut positions = Vec::new();
    for _ in 0..5 {
        std::thread::sleep(Duration::from_millis(150));
        positions.push(handle.position_secs());
    }

    // 验证位置单调递增
    for w in positions.windows(2) {
        assert!(
            w[1] >= w[0],
            "位置应单调递增: {} -> {}", w[0], w[1]
        );
    }

    handle.stop();
}

#[test]
fn test_engine_stop_resets_position() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");
    std::thread::sleep(Duration::from_millis(200));

    handle.stop();
    std::thread::sleep(Duration::from_millis(200));

    assert!(!handle.is_playing(), "stop 后应停止播放");
    let pos = handle.position_secs();
    assert!(
        (pos - 0.0).abs() < 0.01,
        "stop 后位置应归零, 实际: {pos:.3}s"
    );
}

#[test]
fn test_engine_play_after_stop() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    // 第一次播放
    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("第一次 TrackChanged");
    std::thread::sleep(Duration::from_millis(200));
    handle.stop();
    std::thread::sleep(Duration::from_millis(200));
    assert!(!handle.is_playing());

    // 排空残留事件（如 DurationSecs / Position）
    drain_events(&rx);

    // 第二次播放同文件
    handle.play(path.clone());
    let ev = rx.recv_timeout(Duration::from_secs(5))
        .expect("第二次应收到 TrackChanged");
    match ev {
        EngineEvent::TrackChanged(_) => {}, // ok
        other => panic!("期望 TrackChanged, 收到: {other:?}"),
    }
    assert!(handle.is_playing(), "第二次播放后应是播放状态");

    handle.stop();
}

#[test]
fn test_engine_duration_is_reported() {
    let path = ensure_test_wav(); // 1s 文件
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");

    // 收集事件找 DurationSecs
    let events = collect_events(&rx, Duration::from_secs(2));
    let has_duration = events.iter().any(|e| matches!(e, EngineEvent::DurationSecs(_)));

    assert!(has_duration, "应收到 DurationSecs 事件");

    let dur = handle.duration_secs();
    assert!(
        (dur - 1.0).abs() < 0.1,
        "时长应在 1.0s 附近, 实际: {dur:.3}s"
    );

    handle.stop();
}

#[test]
fn test_engine_queue_advances_to_next() {
    let short = ensure_short_wav(); // 0.3s
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 30,
        ..Default::default()
    });

    handle.play_queue(vec![short.clone(), short.clone()]);

    // 等第一首播完 + 第二首开始
    let mut track_changes = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(EngineEvent::TrackChanged(p)) => track_changes.push(p),
            Ok(_) => continue,
            Err(_) => continue, // 超时继续等
        }
    }

    assert!(
        track_changes.len() >= 2,
        "应至少收到 2 次 TrackChanged (自动切歌), 实际 {} 次",
        track_changes.len()
    );

    handle.stop();
}

#[test]
fn test_engine_multiple_commands_stress() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    // 连续发命令不 panic
    for _ in 0..20 {
        handle.play(path.clone());
        handle.pause();
        handle.resume();
        handle.seek(0.1);
    }
    handle.stop();
}

#[test]
fn test_engine_handle_clone_works() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start();

    let h2 = handle.clone();
    h2.play(path.clone());

    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");
    assert!(handle.is_playing());

    handle.stop();
    drop(h2);
}

// ── 极端场景 ──

#[test]
fn test_engine_play_nonexistent_file() {
    let (handle, rx) = EngineHandle::start();

    handle.play("/tmp/_nonexistent_song_12345.wav".into());

    let ev = rx.recv_timeout(Duration::from_secs(5))
        .expect("不存在的文件应返回 Error 事件");
    match ev {
        EngineEvent::Error(ref msg) => assert!(!msg.is_empty(), "错误消息不应为空"),
        other => panic!("期望 Error, 收到: {other:?}"),
    }
    assert!(!handle.is_playing());
}

#[test]
fn test_engine_seek_beyond_end() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start();
    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");

    // seek 到远超出时长，不 panic 即可
    handle.seek(999.0);
    std::thread::sleep(Duration::from_millis(500));

    // 引擎仍可正常操作
    assert!(!handle.is_playing() || handle.position_secs() > 0.0);
    handle.stop();
}

#[test]
fn test_engine_seek_negative() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start();
    handle.play(path.clone());
    rx.recv_timeout(Duration::from_secs(5)).expect("TrackChanged");

    // seek 到负数，不 panic 即可
    handle.seek(-5.0);
    std::thread::sleep(Duration::from_millis(300));

    let pos = handle.position_secs();
    assert!(
        pos >= 0.0 && pos <= 2.0,
        "seek(-5) 后位置应在合理范围, 实际: {pos:.3}s"
    );
    handle.stop();
}

#[test]
fn test_engine_empty_queue() {
    let (handle, rx) = EngineHandle::start();
    // 空队列不应 panic
    handle.play_queue(vec![]);
    std::thread::sleep(Duration::from_millis(200));
    assert!(!handle.is_playing());
    drop(rx);
}

#[test]
fn test_engine_rapid_play_stop_cycles() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();

    // 发命令不 panic 即可（引擎异步处理，不等待完成）
    for _ in 0..10 {
        handle.play(path.clone());
        handle.stop();
    }
    std::thread::sleep(Duration::from_millis(200));
    // 引擎可能已停止，也可能还在处理排队的命令——不掉 panic 就行
    drop(handle);
}

#[test]
fn test_engine_handle_dropped_without_stop() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();
    handle.play(path.clone());
    // 不调 stop，直接 drop handle → 引擎线程应安全退出
    drop(handle);
    std::thread::sleep(Duration::from_millis(200));
}

// ── 极端场景补充 ──

#[test]
fn test_engine_zero_buffer_ms() {
    let path = ensure_test_wav();
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 0,
        ..Default::default()
    });
    handle.play(path.clone());
    let ev = rx.recv_timeout(Duration::from_secs(5)).expect("buffer_ms=0 应正常播放");
    match ev {
        EngineEvent::TrackChanged(_) => {},
        other => panic!("期望 TrackChanged, 收到: {other:?}"),
    }
    assert!(handle.is_playing());
    handle.stop();
}

#[test]
fn test_engine_seek_when_stopped() {
    let (handle, _rx) = EngineHandle::start();
    // 未播放时 seek 不应 panic
    handle.seek(0.5);
    handle.seek(-1.0);
    handle.seek(999.0);
    std::thread::sleep(Duration::from_millis(100));
}

#[test]
fn test_engine_seek_before_play() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();
    // seek 后再 play
    handle.seek(0.3);
    handle.play(path.clone());
    std::thread::sleep(Duration::from_millis(100));
    // 不 panic 即可
    handle.stop();
}

#[test]
fn test_engine_unicode_path() {
    let path = "/tmp/🎵-测试-音乐-♫.wav".to_string();
    generate_wav(&path, 44100, 2, 0.3);
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });
    handle.play(path.clone());
    let ev = rx.recv_timeout(Duration::from_secs(5)).expect("unicode 路径应正常");
    match ev {
        EngineEvent::TrackChanged(ref p) => assert!(p.contains("🎵") || p.contains("测试"),
            "unicode 路径应传回完整: {p}"),
        EngineEvent::Error(ref msg) => panic!("unicode 路径出错: {msg}"),
        other => panic!("期望 TrackChanged, 收到: {other:?}"),
    }
    handle.stop();
    let _ = std::fs::remove_file(&path);
}

#[test]
fn test_engine_extreme_config_values() {
    // 极端配置值不应 panic
    let (_handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        sample_rate: 384000,
        channels: 8,
        buffer_ms: 5000,
        crossfade_ms: 10000,
        ..Default::default()
    });
    // 能创建成功即可，不发 play 命令
    std::thread::sleep(Duration::from_millis(100));
}

#[test]
fn test_engine_play_same_file_twice() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });
    // 连续两次 play 同一文件
    handle.play(path.clone());
    handle.play(path.clone());
    std::thread::sleep(Duration::from_millis(200));
    handle.stop();
}
