//! 播放测试：生成一个短促的 440Hz 测试音验证 cpal 输出
//! 用法: cargo run --example play_test

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use ringbuf::traits::{Consumer, Producer, Split};
use ringbuf::HeapRb;

fn main() {
    let target_rate = 44100u32;
    let target_channels = 2u16;

    let host = cpal::default_host();
    let device = host.default_output_device().expect("无输出设备");
    let config = cpal::StreamConfig {
        channels: target_channels,
        sample_rate: cpal::SampleRate(target_rate),
        buffer_size: cpal::BufferSize::Default,
    };
    println!("设备: {}", device.name().unwrap_or_default());

    let rb = HeapRb::<f32>::new((target_rate as f32 * 0.5) as usize * target_channels as usize);
    let (mut prod, mut cons) = rb.split();

    // 生成 1 秒 440Hz 正弦波
    let total_samples = target_rate as usize * target_channels as usize;
    let mut test_tone = Vec::with_capacity(total_samples);
    for i in 0..total_samples {
        let sample = ((i / target_channels as usize) as f64 / target_rate as f64
            * 440.0
            * 2.0
            * std::f64::consts::PI)
            .sin() as f32
            * 0.3;
        test_tone.push(sample);
    }

    // 先推入 ring buffer
    prod.push_slice(&test_tone);

    let playing = Arc::new(AtomicBool::new(true));
    let p = playing.clone();
    let stream = device
        .build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                if !p.load(Ordering::SeqCst) {
                    data.fill(0.0);
                    return;
                }
                let n = cons.pop_slice(data);
                if n < data.len() {
                    data[n..].fill(0.0);
                }
            },
            |err| eprintln!("cpal 错误: {err}"),
            None,
        )
        .expect("创建音频流失败");

    stream.play().expect("启动播放失败");
    println!("播放 1 秒 440Hz 测试音...");
    std::thread::sleep(Duration::from_secs(2));
    playing.store(false, Ordering::SeqCst);
    drop(stream);
    println!("完成");
}
