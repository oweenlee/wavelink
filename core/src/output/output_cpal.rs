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

use crate::output::{AudioOutput, AudioOutputInner, DeviceConfig, OutputDeviceInfo, PcmProducer, SampleFormat};

/// cpal 音频输出句柄
pub struct AudioOutputCpal {
    /// cpal 音频流句柄
    pub stream: cpal::Stream,
    /// 共享内部状态（consumer ringbuf + underrun 计数）
    pub inner: Arc<AudioOutputInner>,
    playing: Arc<AtomicBool>,
    sample_rate: u32,
    channels: u32,
    /// 保存设备名称用于采样率切换时重建 stream
    device_name: Option<String>,
    buffer_ms: u32,
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

        let mut guard = self.inner.consumer.lock();
        guard.clear();
        *guard = new_cons;

        prod
    }
    fn sample_rate(&self) -> u32 { self.sample_rate }
    fn channels(&self) -> u32 { self.channels }

    fn set_sample_rate(&mut self, rate: u32) -> Result<u32, crate::error::EngineError> {
        if rate == self.sample_rate {
            return Ok(rate);
        }
        info!("采样率切换: {} -> {}Hz", self.sample_rate, rate);
        // 重建 stream
        let host = cpal::default_host();
        let device = match &self.device_name {
            Some(name) => {
                let mut devices = host.devices().map_err(|e| crate::error::EngineError::OutputOpenFailed(format!("枚举设备失败: {e}")))?;
                devices.find(|d| d.name().ok().as_deref() == Some(name))
                    .ok_or_else(|| crate::error::EngineError::OutputOpenFailed(format!("未找到设备: {name}")))?
            }
            None => host.default_output_device()
                .ok_or_else(|| crate::error::EngineError::OutputOpenFailed("未找到默认输出设备".into()))?,
        };

        let config = cpal::StreamConfig {
            channels: self.channels as u16,
            sample_rate: cpal::SampleRate(rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let buf_samples = (rate as f32 * self.buffer_ms as f32 / 1000.0) as usize * self.channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (_producer, consumer) = rb.split();

        // 复用现有 inner：引擎（state.output_inner）持有的是 open() 时返回的 Arc，
        // 若新建 inner，stream_failed/underrun_count 监控会永久失联。
        // 只替换 consumer，计数器归零。
        {
            let mut guard = self.inner.consumer.lock();
            guard.clear();
            *guard = consumer;
        }
        self.inner.underrun_count.store(0, std::sync::atomic::Ordering::Relaxed);
        self.inner.stream_failed.store(false, std::sync::atomic::Ordering::Release);

        // 继承当前 playing 状态：否则切采样率后新流默认静音且无报错
        let playing_clone = self.playing.clone();
        let inner_clone = self.inner.clone();
        let err_inner = self.inner.clone();

        let stream = device.build_output_stream(
            &config,
            move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                if !playing_clone.load(Ordering::Acquire) {
                    data.fill(0.0);
                    return;
                }
                let mut guard = inner_clone.consumer.lock();
                let n = guard.pop_slice(data);
                if n < data.len() {
                    inner_clone.underrun_count.fetch_add(1, Ordering::Relaxed);
                    data[n..].fill(0.0);
                }
            },
            move |err| {
                error!("音频流错误 (rate switch): {err}");
                err_inner.stream_failed.store(true, Ordering::Release);
            },
            None,
        ).map_err(|e| crate::error::EngineError::OutputOpenFailed(format!("采样率 {rate}Hz 不支持: {e}")))?;

        // 停止旧 stream，启动新 stream
        let _ = self.stream.pause();
        if let Err(e) = stream.play() {
            return Err(crate::error::EngineError::OutputOpenFailed(format!("启动新采样率流失败: {e}")));
        }

        self.stream = stream;
        self.sample_rate = rate;
        info!("采样率切换成功: {}Hz", rate);
        Ok(rate)
    }

    fn supported_sample_rates(&self) -> Vec<u32> {
        let host = cpal::default_host();
        let device = match &self.device_name {
            Some(name) => {
                let Ok(mut devices) = host.devices() else { return vec![self.sample_rate] };
                match devices.find(|d| d.name().ok().as_deref() == Some(name)) {
                    Some(d) => d,
                    None => return vec![self.sample_rate],
                }
            }
            None => match host.default_output_device() {
                Some(d) => d,
                None => return vec![self.sample_rate],
            },
        };
        let mut rates: Vec<u32> = device.supported_output_configs()
            .map(|cfgs| cfgs.flat_map(|c| vec![c.min_sample_rate().0, c.max_sample_rate().0]).collect())
            .unwrap_or_default();
        rates.sort();
        rates.dedup();
        if rates.is_empty() {
            rates.push(self.sample_rate);
        }
        rates
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

/// 枚举输出设备（通过 cpal），含格式探测
pub(crate) fn enumerate_devices() -> Vec<OutputDeviceInfo> {
    let host = cpal::default_host();
    let Ok(device_iter) = host.devices() else { return vec![] };
    let default_device = host.default_output_device();
    let common_rates = [44100u32, 48000, 88200, 96000, 176400, 192000];

    let mut result = Vec::new();
    for device in device_iter {
        let Ok(name) = device.name() else { continue };
        let Ok(config_ranges) = device.supported_output_configs() else { continue };

        let mut configs = Vec::new();
        let mut seen = Vec::new();
        for cr in config_ranges {
            let sample_format = match cr.sample_format() {
                cpal::SampleFormat::F32 => SampleFormat::F32,
                cpal::SampleFormat::I16 => SampleFormat::I16,
                cpal::SampleFormat::U16 => SampleFormat::I16,
                cpal::SampleFormat::I32 => SampleFormat::I32,
                _ => continue,
            };
            let channels = cr.channels();
            let min_rate = cr.min_sample_rate().0;
            let max_rate = cr.max_sample_rate().0;
            let bit_depth = match sample_format {
                SampleFormat::I16 => 16,
                SampleFormat::I24 => 24,
                SampleFormat::I32 | SampleFormat::F32 => 32,
            };
            for &rate in &common_rates {
                if rate >= min_rate && rate <= max_rate {
                    let key = (rate, bit_depth, channels, sample_format as u8);
                    if !seen.contains(&key) {
                        seen.push(key);
                        configs.push(DeviceConfig {
                            sample_rate: rate,
                            bit_depth,
                            channels,
                            sample_format,
                            exclusive: false,
                        });
                    }
                }
            }
        }
        if configs.is_empty() {
            for &rate in &[44100u32, 48000, 96000, 192000] {
                configs.push(DeviceConfig {
                    sample_rate: rate,
                    bit_depth: 32,
                    channels: 2,
                    sample_format: SampleFormat::F32,
                    exclusive: false,
                });
            }
        }

        let is_default = default_device.as_ref()
            .and_then(|d| d.name().ok())
            .map(|n| n == name)
            .unwrap_or(false);

        result.push(OutputDeviceInfo {
            id: name.clone(),
            name,
            is_default,
            is_usb: false,
            configs,
        });
    }
    result
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
        consumer: parking_lot::Mutex::new(consumer),
        underrun_count: std::sync::atomic::AtomicU64::new(0),
        stream_failed: std::sync::atomic::AtomicBool::new(false),
    });

    let playing = Arc::new(AtomicBool::new(false));
    let playing_clone = playing.clone();
    let inner_clone = inner.clone();
    let err_inner = inner.clone();

    let build_result = device.build_output_stream(
        &config,
        move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
            if !playing_clone.load(Ordering::Acquire) {
                data.fill(0.0);
                return;
            }
            let mut guard = inner_clone.consumer.lock();
            let n = guard.pop_slice(data);
            if n < data.len() {
                let cnt = inner_clone.underrun_count.fetch_add(1, Ordering::Relaxed) + 1;
                if cnt <= 10 || cnt.is_multiple_of(100) {
                    warn!("音频 underrun #{cnt}: 回调需要 {} 样本但仅读到 {}", data.len(), n);
                }
                data[n..].fill(0.0);
            }
        },
        move |err| {
            error!("音频流错误: {err}");
            err_inner.stream_failed.store(true, Ordering::Release);
        },
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
                sample_rate,
                channels,
                device_name: device_name.map(|s| s.to_string()),
                buffer_ms,
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
                consumer: parking_lot::Mutex::new(fb_cons),
                underrun_count: std::sync::atomic::AtomicU64::new(0),
                stream_failed: std::sync::atomic::AtomicBool::new(false),
            });
            let fb_playing = Arc::new(AtomicBool::new(false));
            let fb_inner_clone = Arc::clone(&fb_inner);
            let fb_playing_clone = fb_playing.clone();
            let fb_err_inner = Arc::clone(&fb_inner);

            let fb_stream = device
                .build_output_stream(
                    &fallback_config,
                    move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                        if !fb_playing_clone.load(Ordering::Acquire) {
                            data.fill(0.0);
                            return;
                        }
                        let mut guard = fb_inner_clone.consumer.lock();
                        let n = guard.pop_slice(data);
                        if n < data.len() {
                            let cnt = fb_inner_clone.underrun_count.fetch_add(1, Ordering::Relaxed) + 1;
                            if cnt <= 10 || cnt.is_multiple_of(100) {
                                warn!("音频 underrun #{} (fallback): 回调需要 {} 样本但仅读到 {}", cnt, data.len(), n);
                            }
                            data[n..].fill(0.0);
                        }
                    },
                    move |err| {
                        error!("音频流错误 (fallback): {err}");
                        fb_err_inner.stream_failed.store(true, Ordering::Release);
                    },
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
                    sample_rate: fallback_rate,
                    channels,
                    device_name: device_name.map(|s| s.to_string()),
                    buffer_ms,
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
