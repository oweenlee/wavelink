//! cpal 音频输出后端
//!
//! 使用 ringbuf::HeapRb 作为消费者线程和音频回调之间的高水位缓冲，
//! 吸收解码/消费线程的瞬时延迟，避免回调因无数据而填入静音。
//!
//! AudioOutput 的生命周期与引擎绑定：首次 play_file 时创建，seek/切歌时
//! 通过 swap_consumer 替换 ringbuf 消费者端，不复建 cpal stream。
//!
//! 采样率 fallback：如果请求的采样率设备不支持，自动回退到设备默认采样率。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use ringbuf::traits::{Consumer, Split};
use ringbuf::HeapRb;
use tracing::{error, info, warn};

use crate::output::{AudioOutput, AudioOutputInner, PcmProducer};

/// cpal 音频输出句柄
pub struct AudioOutputCpal {
    pub stream: cpal::Stream,
    pub inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
}

impl AudioOutput for AudioOutputCpal {
    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
    }
    fn resume(&self) {
        self.playing.store(true, Ordering::Release);
    }
    fn swap_consumer(
        &self,
        buffer_ms: u32,
        sample_rate: u32,
        channels: u32,
    ) -> PcmProducer {
        let buf_samples =
            (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (prod, new_cons) = rb.split();

        if let Ok(mut guard) = self.inner.consumer.lock() {
            guard.clear();
            *guard = new_cons;
        }

        prod
    }
}

impl Drop for AudioOutputCpal {
    fn drop(&mut self) {
        let _ = self.stream.pause();
    }
}

/// 列出所有可用输出设备名称
pub(crate) fn list_device_names() -> Vec<String> {
    let host = cpal::default_host();
    match host.devices() {
        Ok(devices) => devices
            .filter(|d| {
                d.default_output_config().is_ok()
                    || d.supported_output_configs().map(|mut c| c.next().is_some()).unwrap_or(false)
            })
            .filter_map(|d| d.name().ok())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// cpal 内部打开函数，output::open() 封装后暴露出去
pub(crate) fn open_inner(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    device_name: Option<&str>,
) -> Result<(AudioOutputCpal, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    let host = cpal::default_host();
    let device = match device_name {
        Some(name) => {
            let mut devices = host.devices().map_err(|e| format!("枚举设备失败: {e}"))?;
            devices
                .find(|d| d.name().ok().as_deref() == Some(name))
                .ok_or_else(|| format!("未找到输出设备: {name}"))?
        }
        None => host
            .default_output_device()
            .ok_or_else(|| "未找到默认输出设备".to_string())?,
    };

    let config = cpal::StreamConfig {
        channels: channels as u16,
        sample_rate: cpal::SampleRate(sample_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    let buf_samples = (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
    let rb = HeapRb::<f32>::new(buf_samples.max(64));
    let (producer, consumer) = rb.split();

    let inner = Arc::new(AudioOutputInner {
        consumer: std::sync::Mutex::new(consumer),
        underrun_count: std::sync::atomic::AtomicU64::new(0),
    });

    let playing = Arc::new(AtomicBool::new(false));
    let playing_clone = playing.clone();
    let inner_clone = inner.clone();

    let build_result = device.build_output_stream(
        &config,
        move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
            if !playing_clone.load(Ordering::Acquire) {
                data.fill(0.0);
                return;
            }
            if let Ok(mut guard) = inner_clone.consumer.lock() {
                let n = guard.pop_slice(data);
                if n < data.len() {
                    let cnt = inner_clone.underrun_count.fetch_add(1, Ordering::Relaxed) + 1;
                    if cnt <= 10 || cnt % 100 == 0 {
                        warn!("音频 underrun #{cnt}: 回调需要 {} 样本但仅读到 {}", data.len(), n);
                    }
                    data[n..].fill(0.0);
                }
            } else {
                data.fill(0.0);
            }
        },
        |err| error!("音频流错误: {err}"),
        None,
    );

    let stream = match build_result {
        Ok(s) => {
            if let Err(e) = s.play() {
                error!("启动音频流失败: {e}");
            }
            AudioOutputCpal {
                stream: s,
                inner: inner.clone(),
                playing,
            }
        }
        Err(e) => {
            warn!(
                "设备不支持 {}Hz ({}), 回退到默认采样率",
                sample_rate, e
            );
            let default_cfg = device
                .default_output_config()
                .map_err(|e| format!("获取设备默认配置失败: {e}"))?;
            let fallback_rate = default_cfg.sample_rate().0;
            info!("回退采样率: {}Hz", fallback_rate);

            let fallback_config = cpal::StreamConfig {
                channels: channels as u16,
                sample_rate: cpal::SampleRate(fallback_rate),
                buffer_size: cpal::BufferSize::Default,
            };

            let fallback_buf =
                (fallback_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
            let rb = HeapRb::<f32>::new(fallback_buf.max(64));
            let (fb_prod, fb_cons) = rb.split();
            let fb_inner = Arc::new(AudioOutputInner {
                consumer: std::sync::Mutex::new(fb_cons),
                underrun_count: std::sync::atomic::AtomicU64::new(0),
            });
            let fb_playing = Arc::new(AtomicBool::new(false));
            let fb_inner_clone = Arc::clone(&fb_inner);
            let fb_playing_clone = fb_playing.clone();

            let fb_stream = device
                .build_output_stream(
                    &fallback_config,
                    move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                        if !fb_playing_clone.load(Ordering::Acquire) {
                            data.fill(0.0);
                            return;
                        }
                        if let Ok(mut guard) = fb_inner_clone.consumer.lock() {
                            let n = guard.pop_slice(data);
                            if n < data.len() {
                                let cnt = fb_inner_clone.underrun_count.fetch_add(1, Ordering::Relaxed) + 1;
                                if cnt <= 10 || cnt % 100 == 0 {
                                    warn!("音频 underrun #{} (fallback): 回调需要 {} 样本但仅读到 {}", cnt, data.len(), n);
                                }
                                data[n..].fill(0.0);
                            }
                        } else {
                            data.fill(0.0);
                        }
                    },
                    |err| error!("音频流错误: {err}"),
                    None,
                )
                .map_err(|e| format!("回退采样率后仍失败: {e}"))?;

            if let Err(e) = fb_stream.play() {
                error!("启动回退音频流失败: {e}");
            }

            return Ok((
                AudioOutputCpal {
                    stream: fb_stream,
                    inner: Arc::clone(&fb_inner),
                    playing: fb_playing,
                },
                fb_prod,
                fb_inner,
                fallback_rate,
            ));
        }
    };

    let actual_rate = sample_rate;

    info!(
        "输出设备: {}, {}Hz {}ch, 缓冲: {}ms",
        device.name().unwrap_or_default(),
        actual_rate,
        channels,
        buffer_ms,
    );

    Ok((stream, producer, inner, actual_rate))
}
