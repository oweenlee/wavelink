//! 复现：headless 引擎播放但无人消费 ringbuf → consumer 是否 100% 空转
//! 用法: cargo run --release --example spin_repro --no-default-features
#[cfg(target_os = "macos")]
#[allow(clippy::duplicated_attributes)] // 多个 #[link] 的 kind = "framework" 会被 clippy 误报为重复属性
#[link(name = "CoreAudio", kind = "framework")]
#[link(name = "AudioToolbox", kind = "framework")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {}

use audio_core::engine::EngineHandle;
use audio_core::EngineConfig;
use std::time::Duration;

fn main() {
    // 生成 30 秒 48k 立体声 wav
    let path = "/tmp/wavelink_spin_test.wav";
    let spec = hound::WavSpec { channels: 2, sample_rate: 48000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    for i in 0..(48000 * 30) {
        let s = ((i as f32 / 48000.0 * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.3 * i16::MAX as f32) as i16;
        w.write_sample(s).unwrap();
        w.write_sample(s).unwrap();
    }
    w.finalize().unwrap();

    let config = EngineConfig { sample_rate: 48000, channels: 2, buffer_ms: 280, ..Default::default() };
    let (handle, _rx) = EngineHandle::start_with_config(config);
    handle.play_sync(path.to_string()).expect("play failed");
    eprintln!("playing, NOT consuming ringbuf; pid = {}", std::process::id());
    std::thread::sleep(Duration::from_secs(120));
    handle.stop();
}
