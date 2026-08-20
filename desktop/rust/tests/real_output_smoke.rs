//! 桌面端真实输出冒烟测试（诊断"没声音"用，非 CI 日常测试）。
//!
//! 绕过 FRB 宏直接驱动 audio_core（app 桥接层是薄封装）：
//! 真实 cpal 后端在本机初始化引擎并播放测试音，
//! 默认设备 + 指定设备名（镜像 App 的 outputDevice 偏好）两条路径，
//! 断言引擎进入 playing 且无 error 事件。失败时打印设备枚举与错误。
//!
//! 注意：本测试会真的出声几秒，勿加入日常 CI。

use std::time::Duration;

use audio_core::engine::{EngineEvent, EngineHandle};

fn write_sine(path: &str, secs: u64) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44100,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    let n = 44100 * secs;
    for i in 0..n {
        let t = i as f64 / 44100.0;
        let s = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.3;
        let v = (s * i16::MAX as f64) as i16;
        w.write_sample(v).unwrap();
        w.write_sample(v).unwrap();
    }
    w.finalize().unwrap();
}

fn play_and_check(path: &str, device: Option<String>, label: &str) {
    eprintln!("=== {label} ===");
    let (handle, rx) = EngineHandle::start_with_config(audio_core::EngineConfig {
        sample_rate: 44100,
        channels: 2,
        buffer_ms: 280,
        output_device: device,
        ..Default::default()
    });
    handle.play(path.to_string());

    let mut became_playing = false;
    let mut errors = Vec::new();
    for _ in 0..40 {
        while let Ok(ev) = rx.try_recv() {
            match ev {
                EngineEvent::Error(e) => {
                    eprintln!("[{label}] ERROR EVENT: {e}");
                    errors.push(e);
                }
                other => eprintln!("[{label}] event: {other:?}"),
            }
        }
        if handle.is_playing() {
            became_playing = true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    eprintln!(
        "[{label}] became_playing={became_playing} errors={} underruns={}",
        errors.len(),
        handle.underrun_count()
    );
    handle.stop();
    assert!(became_playing, "[{label}] 引擎未进入播放状态");
    assert!(
        errors.is_empty(),
        "[{label}] 播放链路出现错误: {errors:?}"
    );
}

/// 诊断入口：`cargo test --test real_output_smoke -- --ignored --nocapture`。
#[test]
#[ignore = "真实出声的诊断测试：按需运行 cargo test --test real_output_smoke -- --ignored"]
fn local_play_real_output_smoke() {
    let path = "/tmp/wavelink_smoke_out.wav";
    write_sine(path, 3);

    let devices = audio_core::output::enumerate_devices();
    eprintln!("[devices] {} 台:", devices.len());
    for d in &devices {
        eprintln!("  - {:?} (id={}, default={})", d.name, d.id, d.is_default);
    }

    // 路径 1：默认设备（None）
    play_and_check(path, None, "default-device");

    // 路径 2：镜像 App 偏好里保存的具名设备。
    // App 偏好当前是 "MacBook Pro扬声器"；用 cpal 枚举到的真实名字保持一致，
    // 并额外试一次汉字扬声器名（若枚举中恰好有）。
    for name in devices
        .iter()
        .map(|d| d.name.clone())
        .chain(std::iter::once("MacBook Pro扬声器".to_string()))
    {
        if !devices.iter().any(|d| d.name == name) {
            eprintln!("[named-device] 设备不存在于枚举列表，跳过: {name}");
            continue;
        }
        play_and_check(path, Some(name.clone()), "named-device");
        break;
    }
}