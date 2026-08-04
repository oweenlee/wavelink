//! 并发压力测试
//!
//! 验证 EngineHandle 在多线程并发调用下的安全性。
//! 包括：并发命令、跨线程 clone/drop 等。

use std::sync::Arc;
use std::time::Duration;

use audio_core::engine::EngineHandle;
use audio_core::EngineConfig;

fn ensure_test_wav() -> String {
    let path = "/tmp/_concurrent_test_tone.wav".to_string();
    if !std::path::Path::new(&path).exists() {
        let spec = hound::WavSpec {
            channels: 2,
            sample_rate: 44100,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(&path, spec).unwrap();
        let n = (44100.0 * 0.5) as u32 * 2;
        for i in 0..n {
            let t = i as f64 / 44100.0;
            let s = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.5;
            writer.write_sample((s * i16::MAX as f64) as i16).unwrap();
        }
        writer.finalize().unwrap();
    }
    path
}

/// 8 个线程同时发 play/pause/seek/stop 命令，验证不 panic
#[test]
fn test_concurrent_commands_no_panic() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    let handle = Arc::new(handle);
    let mut threads = Vec::new();

    for ti in 0..8 {
        let h = Arc::clone(&handle);
        let p = path.clone();
        threads.push(std::thread::spawn(move || {
            for _ in 0..50 {
                h.play(p.clone());
                h.pause();
                h.resume();
                h.seek(0.1 + ti as f64 * 0.01);
                // 偶尔查询状态
                let _ = h.is_playing();
                let _ = h.position_secs();
                let _ = h.duration_secs();
            }
        }));
    }

    for t in threads {
        t.join().expect("并发线程不应 panic");
    }

    // 验证引擎仍可用
    assert!(!handle.is_playing());
    handle.stop();
}

/// 跨线程 clone 然后独立使用
#[test]
fn test_handle_clone_across_threads() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();

    let h2 = handle.clone();
    let h3 = handle.clone();
    let p2 = path.clone();
    let p3 = path;

    let t2 = std::thread::spawn(move || {
        h2.play(p2);
        std::thread::sleep(Duration::from_millis(100));
        // 可能播的是本线程的文件，也可能被对方覆盖，不重要——不 panic 即可
        h2.stop();
    });

    let t3 = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        h3.play(p3);
        std::thread::sleep(Duration::from_millis(100));
        h3.stop();
    });

    t2.join().expect("线程 2 不应 panic");
    t3.join().expect("线程 3 不应 panic");

    assert!(!handle.is_playing());
    handle.stop();
}

/// 多线程同时 stop，验证幂等性
#[test]
fn test_concurrent_stop_idempotent() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();

    handle.play(path.clone());
    std::thread::sleep(Duration::from_millis(50));

    let h = Arc::new(handle);
    let mut threads = Vec::new();
    for _ in 0..10 {
        let h = Arc::clone(&h);
        threads.push(std::thread::spawn(move || {
            h.stop();
        }));
    }

    for t in threads {
        t.join().expect("并发 stop 不应 panic");
    }

    std::thread::sleep(Duration::from_millis(100));
    assert!(!h.is_playing());
}

/// 大量 clone → drop 轮换，验证引用计数安全
#[test]
fn test_handle_clone_drop_storm() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();

    let mut clones = Vec::new();
    for _ in 0..100 {
        let h = handle.clone();
        clones.push(h);
    }

    // 交错播放 + drop
    for (i, h) in clones.iter().enumerate() {
        h.play(path.clone());
        if i % 10 == 0 {
            h.stop();
        }
    }

    // drop 所有 clone，只剩原始 handle
    drop(clones);

    assert!(!handle.is_playing());
    handle.stop();
}

// ── 极端场景补充 ──

/// 多线程并发 seek 到极端值
#[test]
fn test_concurrent_extreme_seek() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });
    handle.play(path.clone());
    std::thread::sleep(Duration::from_millis(50));

    let handle = Arc::new(handle);
    let mut threads = Vec::new();

    for _ in 0..8 {
        let h = Arc::clone(&handle);
        threads.push(std::thread::spawn(move || {
            for _ in 0..20 {
                h.seek(-5.0);   // 负值
                h.seek(999.0);  // 远超时长
                h.seek(0.0);    // 起点
                h.seek(0.001);  // 极小值
            }
        }));
    }

    for t in threads {
        t.join().expect("极端 seek 线程不应 panic");
    }
    handle.stop();
}

/// 同一进程创建多个独立 EngineHandle 实例
#[test]
fn test_multi_engine_instances() {
    let path = ensure_test_wav();
    let (handle1, _rx1) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });
    let (handle2, _rx2) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    // 用 play_sync 等引擎完成 consumer ready 握手后再断言，
    // 避免固定 sleep 对 0.5s 短文件的播放时序敏感（flaky 来源）
    handle1.play_sync(path.clone()).expect("引擎1启动播放");
    handle2.play_sync(path.clone()).expect("引擎2启动播放");

    assert!(handle1.is_playing(), "引擎1应处于播放状态");
    assert!(handle2.is_playing(), "引擎2应处于播放状态");
    handle1.stop();
    handle2.stop();
}

/// 大量并发 query 操作不 panic
#[test]
fn test_concurrent_queries_stress() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });
    handle.play(path.clone());
    std::thread::sleep(Duration::from_millis(50));

    let handle = Arc::new(handle);
    let mut threads = Vec::new();

    for _ in 0..16 {
        let h = Arc::clone(&handle);
        threads.push(std::thread::spawn(move || {
            for _ in 0..100 {
                let _ = h.is_playing();
                let _ = h.position_secs();
                let _ = h.duration_secs();
                let _ = h.underrun_count();
            }
        }));
    }

    for t in threads {
        t.join().expect("并发 query 线程不应 panic");
    }
    handle.stop();
}

/// 先大量 clone handle 再交错 drop，验证线程安全
#[test]
fn test_handle_clone_drop_in_threads() {
    let path = ensure_test_wav();
    let (handle, _rx) = EngineHandle::start();
    handle.play(path.clone());
    std::thread::sleep(Duration::from_millis(50));

    let handle = Arc::new(handle);
    let mut handles = Vec::new();

    // 在 4 个线程中各 clone 25 个 handle
    for _ in 0..4 {
        let h = Arc::clone(&handle);
        let t = std::thread::spawn(move || {
            let mut local = Vec::new();
            for _ in 0..25 {
                local.push(h.clone());
            }
            // 交错 drop
            for h in local {
                drop(h);
            }
        });
        handles.push(t);
    }

    for t in handles {
        t.join().expect("clone/drop 线程不应 panic");
    }
    handle.stop();
}
