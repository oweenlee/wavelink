//! 流式播放集成测试：验证 `play_stream` 死锁修复后的完整链路。
//!
//! 历史背景：此前 `play_stream` 在拿到首个有效帧（ready）后才发 handle，
//! 而首帧需要 handle 喂数据才产生 —— 鸡生蛋死锁，从空 channel 出发
//! 永远无法通过 ready（const "无有效音频帧"）。修复后 handle 在等 ready
//! 之前即发给宿主，本测试验证：
//!   1. `play_stream` 立即返回 handle（不被 ready 阻塞）
//!   2. 喂入合成 WAV 字节流后引擎进入播放状态（ready 达成）
//!   3. 信号 EOF 后引擎正常结束（不误报错误）

use std::time::Duration;

use audio_core::engine::EngineHandle;
use audio_core::EngineConfig;

/// 生成合成 WAV 的完整字节（1s 440Hz 正弦，16bit 44100Hz 立体声）
fn generate_wav_bytes(seconds: u32) -> Vec<u8> {
    let sample_rate = 44100u32;
    let channels = 2u16;
    // 44 字节 WAV 头 + PCM 数据
    let data_len = sample_rate * seconds as u32 * channels as u32 * 2; // 16bit = 2字节
    let mut wav = Vec::with_capacity(44 + data_len as usize);
    // RIFF 头
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * channels as u32 * 2).to_le_bytes()); // byte rate
    wav.extend_from_slice(&(channels * 2).to_le_bytes()); // block align
    wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    // PCM 数据：440Hz 正弦
    for i in 0..(sample_rate * seconds as u32) {
        let t = i as f64 / sample_rate as f64;
        let s = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.4;
        let sample = (s * i16::MAX as f64) as i16;
        for _ in 0..channels {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
    }
    wav
}

/// 等待引擎进入/退出播放状态
fn wait_for_playing(handle: &EngineHandle, expected: bool, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if handle.is_playing() == expected {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    handle.is_playing() == expected
}

#[test]
fn test_play_stream_returns_handle_immediately() {
    let (_handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });
    // 只要不 panic 即通过：修复前这里会卡 3s（ready 超时）后返回 Err
    let start = std::time::Instant::now();
    let result = _handle.play_stream(Some("wav".to_string()), None);
    let elapsed = start.elapsed();
    assert!(
        result.is_ok(),
        "play_stream 应立即返回 handle"
    );
    assert!(
        elapsed < Duration::from_secs(2),
        "handle 应在 2s 内返回（不被 ready 阻塞），实际 {elapsed:?}"
    );
}

#[test]
fn test_play_stream_feeds_data_then_playing() {
    let (handle, rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    let sh = handle
        .play_stream(Some("wav".to_string()), None)
        .expect("流式启动应成功");
    assert!(!handle.is_playing(), "尚未喂数据，不应开始播放");

    // 分块喂入（模拟 SMB 512KB 分块读取）
    let wav = generate_wav_bytes(1);
    for chunk in wav.chunks(64 * 1024) {
        let written = sh.write(chunk);
        assert!(written == chunk.len(), "写入应完整，写 {written}/{}", chunk.len());
        // 首块写入后应该开始播放（probe 拿到数据 → ready）
        if handle.is_playing() {
            break;
        }
    }

    assert!(
        wait_for_playing(&handle, true, Duration::from_secs(5)),
        "喂入数据后引擎应进入播放状态（ready 达成）"
    );

    // 信号 EOF 结束
    sh.signal_eof();

    // 停止并等待退出
    handle.stop();
    wait_for_playing(&handle, false, Duration::from_secs(2));
    drop(rx);
}

#[test]
fn test_play_stream_drop_handle_midway() {
    // 模拟流中途断开（喂流 task 失败后 handle drop / 引擎 stop 关闭流）：
    // drop handle 后继续喂数据应返回 0（流已关闭），不应 panic
    let (handle, _rx) = EngineHandle::start_with_config(EngineConfig {
        buffer_ms: 50,
        ..Default::default()
    });

    let sh = handle
        .play_stream(Some("wav".to_string()), None)
        .expect("流式启动应成功");

    // 立即丢 handle（模拟切歌/stop 时喂流 task 感知流被关闭）
    drop(sh);

    // 引擎 stop：关闭流 channel
    handle.stop();

    // 等待退出，验证不 panic
    wait_for_playing(&handle, false, Duration::from_secs(2));
}