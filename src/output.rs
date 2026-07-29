//! 音频输出抽象层
//!
//! 定义 AudioOutput trait，各平台后端分别实现。
//! - 桌面端: cpal 后端 (output_cpal)
//! - 移动端/无设备: HeadlessOutput (ringbuf → FFI)

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;
use ringbuf::traits::Split;
use ringbuf::{HeapCons, HeapProd, HeapRb};

/// 解码端向 ring buffer 推入样本的生产端
pub type PcmProducer = HeapProd<f32>;

/// 被音频回调和引擎线程共享的内部状态
pub struct AudioOutputInner {
    /// ringbuf 消费者端，回调通过它读取样本
    /// 使用 parking_lot::Mutex：无内核调用，适配实时音频回调线程
    pub consumer: Mutex<HeapCons<f32>>,
    /// underrun 计数（回调读不到数据时递增）
    pub underrun_count: AtomicU64,
    /// 音频流是否发生错误（设备断开等），引擎可据此尝试恢复
    pub stream_failed: AtomicBool,
}

/// 样本格式
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum SampleFormat {
    /// 16-bit 有符号整数 PCM
    I16,
    /// 24-bit 有符号整数 PCM（3 字节 packed）
    I24,
    /// 32-bit 有符号整数 PCM
    I32,
    /// 32-bit IEEE 浮点
    F32,
}

/// 设备支持的单个配置（采样率/位深/声道/独占组合）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DeviceConfig {
    /// 采样率 Hz
    pub sample_rate: u32,
    /// 位深（有效位）
    pub bit_depth: u8,
    /// 声道数
    pub channels: u16,
    /// 样本格式
    pub sample_format: SampleFormat,
    /// 是否在独占模式下可用
    pub exclusive: bool,
}

/// 输出设备详细信息
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OutputDeviceInfo {
    /// 设备唯一 ID（系统级）
    pub id: String,
    /// 显示名称（友好名）
    pub name: String,
    /// 是否为系统默认设备
    pub is_default: bool,
    /// 是否为 USB 总线设备（DAC 等外置声卡）
    pub is_usb: bool,
    /// 支持的配置列表
    pub configs: Vec<DeviceConfig>,
}

/// 源音频格式（来自当前播放文件）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SourceFormat {
    /// 原文件采样率 Hz
    pub sample_rate: u32,
    /// 原文件有效位深
    pub bit_depth: u8,
    /// 声道数
    pub channels: u16,
    /// 是否为 DSD
    pub is_dsd: bool,
    /// DSD 原始速率（如 2822400）
    pub dsd_rate: Option<u32>,
}

/// 输出决策结果
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OutputDecision {
    /// 目标设备 ID
    pub device_id: String,
    /// 实际输出采样率
    pub sample_rate: u32,
    /// 实际输出位深
    pub bit_depth: u8,
    /// 实际输出样本格式
    pub sample_format: SampleFormat,
    /// 是否独占模式
    pub exclusive: bool,
    /// 是否需要重采样
    pub need_resample: bool,
    /// 是否需要 DoP（DSD over PCM）
    pub need_dop: bool,
    /// 决策说明（给 UI 展示）
    pub reason: String,
}

/// 输出决策错误
#[derive(Debug, Clone)]
pub enum OutputError {
    /// 无可用设备
    NoDevice,
    /// 无兼容配置
    NoCompatibleConfig(String),
}

impl std::fmt::Display for OutputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OutputError::NoDevice => write!(f, "无可用的输出设备"),
            OutputError::NoCompatibleConfig(msg) => write!(f, "{}", msg),
        }
    }
}

/// 音频输出 trait，各平台后端分别实现
pub trait AudioOutput {
    /// 暂停输出（回调填入静音）
    fn pause(&self);
    /// 恢复输出
    fn resume(&self);
    /// 创建新 ringbuf，原子替换消费者端（seek/切歌时用）
    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer;
    /// 当前输出采样率（Hz）
    fn sample_rate(&self) -> u32;
    /// 当前输出声道数
    fn channels(&self) -> u32;

    /// 请求切换输出采样率，返回实际生效的采样率。
    /// 桌面端：重新配置 cpal stream；移动端 Headless：通知平台层重设。
    /// 默认实现：不支持切换，返回当前采样率。
    fn set_sample_rate(&mut self, _rate: u32) -> Result<u32, crate::error::EngineError> {
        Ok(self.sample_rate())
    }

    /// 查询设备支持的采样率列表。
    /// 默认实现：仅返回当前采样率。
    fn supported_sample_rates(&self) -> Vec<u32> {
        vec![self.sample_rate()]
    }

    /// 设置目标位深（仅部分后端生效，如 WASAPI Exclusive）。
    fn set_bit_depth(&mut self, _depth: u16) {}
    /// 动态调整缓冲时长（毫秒），仅部分后端支持实时调整。
    fn set_buffer_ms(&mut self, _ms: u32) {}
}

// ─── HeadlessOutput ──────────────────────────────────────────

struct HeadlessOutput {
    inner: Arc<AudioOutputInner>,
    playing: AtomicBool,
    sample_rate: u32,
    channels: u32,
}

impl AudioOutput for HeadlessOutput {
    fn pause(&self) {
        self.playing.store(false, Ordering::Release);
    }
    fn resume(&self) {
        self.playing.store(true, Ordering::Release);
    }
    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer {
        let buf_samples =
            (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
        let rb = HeapRb::<f32>::new(buf_samples.max(64));
        let (prod, new_cons) = rb.split();
        let mut guard = self.inner.consumer.lock();
        let _ = std::mem::replace(&mut *guard, new_cons);
        prod
    }
    fn sample_rate(&self) -> u32 { self.sample_rate }
    fn channels(&self) -> u32 { self.channels }
}

// ─── cpal 后端 ───────────────────────────────────────────────

#[cfg(feature = "cpal-backend")]
mod output_cpal;

#[cfg(feature = "oboe-backend")]
mod output_oboe;

#[cfg(all(feature = "audiounit-backend", any(target_os = "macos", target_os = "ios")))]
mod output_audiounit;

#[cfg(feature = "wasapi-backend")]
#[cfg(target_os = "windows")]
mod output_wasapi;

#[cfg(target_os = "macos")]
mod output_coreaudio;

// ─── open ────────────────────────────────────────────────────

/// 打开输出设备。
///
/// 后端选择优先级:
///   1. Windows WASAPI Exclusive（wasapi-backend feature）
///   2. macOS/iOS AudioUnit（audiounit-backend feature，低延迟 + 整数直出）
///   3. Android Oboe/AAudio Exclusive（oboe-backend feature）
///   4. cpal 共享模式（cpal-backend feature，跨平台 fallback）
///   5. HeadlessOutput（ringbuf 无输出设备，纯数据模式）
///
/// `bit_depth` 在 WASAPI、AudioUnit、Oboe 后端用于格式协商，其他后端忽略。
#[cfg_attr(not(any(feature = "cpal-backend", all(feature = "wasapi-backend", target_os = "windows"), all(feature = "audiounit-backend", any(target_os = "macos", target_os = "ios")), all(feature = "oboe-backend", target_os = "android"))), allow(unused_variables))]
pub fn open(
    channels: u32,
    sample_rate: u32,
    buffer_ms: u32,
    device_name: Option<&str>,
    _bit_depth: u16,
    _exclusive: bool,
) -> Result<(Box<dyn AudioOutput>, PcmProducer, Arc<AudioOutputInner>, u32), String> {
    // WASAPI Exclusive 后端 (仅 Windows)
    #[cfg(all(feature = "wasapi-backend", target_os = "windows"))]
    {
        if let Ok(result) = output_wasapi::open_inner(channels, sample_rate, buffer_ms, device_name, _bit_depth, _exclusive)
        {
            return Ok((Box::new(result.0) as Box<dyn AudioOutput>, result.1, result.2, result.3));
        }
    }

    // macOS/iOS AudioUnit 后端（低延迟 + 整数直出）
    #[cfg(all(feature = "audiounit-backend", any(target_os = "macos", target_os = "ios")))]
    {
        if let Ok(result) = output_audiounit::open_inner(channels, sample_rate, buffer_ms, device_name, _bit_depth)
        {
            return Ok((Box::new(result.0) as Box<dyn AudioOutput>, result.1, result.2, result.3));
        }
    }

    // Android Oboe/AAudio 后端（独占模式 + 整数直出）
    #[cfg(all(feature = "oboe-backend", target_os = "android"))]
    {
        if let Ok(result) = output_oboe::open_inner(channels, sample_rate, buffer_ms, device_name, _bit_depth)
        {
            return Ok((Box::new(result.0) as Box<dyn AudioOutput>, result.1, result.2, result.3));
        }
    }

    // cpal 共享模式（跨平台 fallback）
    #[cfg(feature = "cpal-backend")]
    {
        if let Ok(result) = output_cpal::open_inner(channels, sample_rate, buffer_ms, device_name)
        {
            return Ok((Box::new(result.0) as Box<dyn AudioOutput>, result.1, result.2, result.3));
        }
    }

    // Headless 模式
    let buf_samples =
        (sample_rate as f32 * buffer_ms as f32 / 1000.0) as usize * channels as usize;
    let rb = HeapRb::<f32>::new(buf_samples.max(64));
    let (prod, cons) = rb.split();
    let inner = Arc::new(AudioOutputInner {
        consumer: Mutex::new(cons),
        underrun_count: AtomicU64::new(0),
        stream_failed: AtomicBool::new(false),
    });
    let out = HeadlessOutput {
        inner: inner.clone(),
        playing: AtomicBool::new(true),
        sample_rate,
        channels,
    };
    Ok((Box::new(out) as Box<dyn AudioOutput>, prod, inner, sample_rate))
}

/// 列出所有可用输出设备名称
pub fn list_device_names() -> Vec<String> {
    #[cfg(all(feature = "wasapi-backend", target_os = "windows"))]
    {
        let wasapi_devices = output_wasapi::list_device_names();
        if !wasapi_devices.is_empty() {
            return wasapi_devices;
        }
    }

    #[cfg(feature = "cpal-backend")]
    {
        output_cpal::list_device_names()
    }

    #[cfg(not(feature = "cpal-backend"))]
    Vec::new()
}

/// 枚举所有输出设备（含详细配置信息）
///
/// 平台优先级:
///   Windows + wasapi-backend → WASAPI 原生枚举 + 格式探测
///   macOS → CoreAudio 原生枚举 + 采样率探测
///   其他 → cpal 设备名列表
pub fn enumerate_devices() -> Vec<OutputDeviceInfo> {
    #[cfg(all(feature = "wasapi-backend", target_os = "windows"))]
    {
        return output_wasapi::enumerate_devices();
    }

    #[cfg(target_os = "macos")]
    {
        let macos_devices = output_coreaudio::enumerate_devices();
        if !macos_devices.is_empty() {
            return macos_devices;
        }
    }

    // Android Oboe 后端
    #[cfg(all(feature = "oboe-backend", target_os = "android"))]
    {
        return output_oboe::enumerate_devices();
    }

    #[cfg(feature = "cpal-backend")]
    {
        output_cpal::enumerate_devices()
    }

    // macOS 无 cpal 时 fallback 到空（CoreAudio 本身已处理）
    #[cfg(not(any(all(feature = "wasapi-backend", target_os = "windows"), all(feature = "oboe-backend", target_os = "android"), feature = "cpal-backend")))]
    Vec::new()
}

// ─── 设备热插拔检测 ─────────────────────────────────────────

/// 设备热插拔事件
#[derive(Debug, Clone)]
pub enum DeviceEvent {
    /// 新设备已添加（携带设备名）
    DeviceAdded(String),
    /// 设备已移除（携带设备名）
    DeviceRemoved(String),
    /// 默认输出设备已变更
    DefaultDeviceChanged,
}

/// 设备热插拔监视器。
///
/// 通过轮询 [`enumerate_devices()`] 检测设备变化，约 1.2 秒检测一次。
/// Drop 时自动停止。
pub struct DeviceMonitor {
    stop_flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
    rx: crossbeam_channel::Receiver<DeviceEvent>,
}

impl DeviceMonitor {
    /// 获取事件接收端
    pub fn receiver(&self) -> &crossbeam_channel::Receiver<DeviceEvent> {
        &self.rx
    }
}

impl Drop for DeviceMonitor {
    fn drop(&mut self) {
        self.stop_flag.store(true, std::sync::atomic::Ordering::Release);
    }
}

/// 启动设备热插拔监视。
///
/// 返回 [`DeviceMonitor`]，通过 `receiver()` 接收设备变化事件。
pub fn start_device_monitor() -> DeviceMonitor {
    let stop_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = stop_flag.clone();
    let (tx, rx) = crossbeam_channel::unbounded();

    std::thread::Builder::new()
        .name("device-monitor".into())
        .spawn(move || {
            let mut prev: Vec<OutputDeviceInfo> = Vec::new();

            while !flag.load(std::sync::atomic::Ordering::Acquire) {
                std::thread::sleep(std::time::Duration::from_millis(1200));

                let cur = enumerate_devices();
                if cur.is_empty() {
                    continue;
                }

                if prev.is_empty() {
                    prev = cur;
                    continue;
                }

                for device in &cur {
                    if !prev.iter().any(|d| d.id == device.id)
                        && tx.send(DeviceEvent::DeviceAdded(device.name.clone())).is_err() {
                            return;
                        }
                }

                for device in &prev {
                    if !cur.iter().any(|d| d.id == device.id)
                        && tx.send(DeviceEvent::DeviceRemoved(device.name.clone())).is_err() {
                            return;
                        }
                }

                let prev_default = prev.iter().find(|d| d.is_default);
                let cur_default = cur.iter().find(|d| d.is_default);
                match (prev_default, cur_default) {
                    (Some(p), Some(c)) if p.id != c.id => {
                        if tx.send(DeviceEvent::DefaultDeviceChanged).is_err() { return; }
                    }
                    (Some(_), None) | (None, Some(_)) => {
                        if tx.send(DeviceEvent::DefaultDeviceChanged).is_err() { return; }
                    }
                    _ => {}
                }

                prev = cur;
            }
        })
        .ok();

    DeviceMonitor { stop_flag, rx }
}

// ─── 输出决策 ────────────────────────────────────────────────

fn find_exact_match<'a>(
    configs: &[&'a DeviceConfig],
    source: &SourceFormat,
) -> Option<&'a DeviceConfig> {
    configs.iter().find(|c| {
        c.sample_rate == source.sample_rate
            && c.channels == source.channels
            && c.bit_depth >= source.bit_depth
    }).copied()
}

fn find_sample_rate_match<'a>(
    configs: &[&'a DeviceConfig],
    sample_rate: u32,
) -> Option<&'a DeviceConfig> {
    configs.iter()
        .filter(|c| c.sample_rate == sample_rate)
        .max_by_key(|c| c.bit_depth)
        .copied()
}

fn choose_best_target_rate<'a>(
    configs: &[&'a DeviceConfig],
    source_rate: u32,
) -> Result<&'a DeviceConfig, OutputError> {
    configs.iter()
        .min_by_key(|c| {
            let diff = (c.sample_rate as i64 - source_rate as i64).abs();
            (diff, -(c.bit_depth as i32))
        })
        .copied()
        .ok_or(OutputError::NoCompatibleConfig("设备无可用的采样率配置".into()))
}

/// 输出决策入口
///
/// 三层决策：完美匹配 → 采样率匹配 → 重采样
pub fn decide_output(
    device: &OutputDeviceInfo,
    source: &SourceFormat,
    prefer_exclusive: bool,
) -> Result<OutputDecision, OutputError> {
    let mut candidates: Vec<&DeviceConfig> = device.configs.iter().collect();

    // 优先只看独占模式的配置
    if prefer_exclusive {
        let exclusive: Vec<_> = candidates.iter().filter(|c| c.exclusive).copied().collect();
        if !exclusive.is_empty() {
            candidates = exclusive;
        }
    }

    // 1. 完美匹配（采样率 + 位深 + 声道）
    if let Some(cfg) = find_exact_match(&candidates, source) {
        return Ok(OutputDecision {
            device_id: device.id.clone(),
            sample_rate: cfg.sample_rate,
            bit_depth: cfg.bit_depth,
            sample_format: cfg.sample_format,
            exclusive: cfg.exclusive,
            need_resample: false,
            need_dop: false,
            reason: format!(
                "完美匹配 {}Hz/{}bit {}",
                cfg.sample_rate,
                cfg.bit_depth,
                if cfg.exclusive { "独占" } else { "共享" },
            ),
        });
    }

    // 2. 采样率匹配（位深可调整）
    if let Some(cfg) = find_sample_rate_match(&candidates, source.sample_rate) {
        return Ok(OutputDecision {
            device_id: device.id.clone(),
            sample_rate: cfg.sample_rate,
            bit_depth: cfg.bit_depth,
            sample_format: cfg.sample_format,
            exclusive: cfg.exclusive,
            need_resample: false,
            need_dop: false,
            reason: format!(
                "采样率匹配 {}Hz，位深调整为 {}bit",
                cfg.sample_rate, cfg.bit_depth,
            ),
        });
    }

    // 3. 必须重采样
    let target = choose_best_target_rate(&candidates, source.sample_rate)?;
    Ok(OutputDecision {
        device_id: device.id.clone(),
        sample_rate: target.sample_rate,
        bit_depth: target.bit_depth,
        sample_format: target.sample_format,
        exclusive: target.exclusive,
        need_resample: true,
        need_dop: false,
        reason: format!(
            "已重采样至 {}Hz/{}bit",
            target.sample_rate, target.bit_depth,
        ),
    })
}
