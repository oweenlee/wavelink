# wavelink-audio-core API Reference

> 源码 hash: `5329a3568d19`  |  生成时间: 2026-07-19 17:35
> AI 助手优先读此文件，而非读 `src/` 源码。若 AI 返回的代码与当前签名不匹配，请重新运行 `bash doc-api.sh`。

---

### `lib.rs` — 纯 Rust 跨端音频引擎：解码 / DSP 管线 / 频谱分析 / BPM 调性检测。

音频文件解码（Symphonia 流式解码 + WavPack + DSD）  
```rust
pub mod decoder;
```

DSD（DSF/DFF）格式直解为 PCM  
```rust
pub mod dsd;
```

DSP 管线：参数均衡器 / 串音补偿 / 立体声展宽 / 限幅 / 抖动  
```rust
pub mod dsp;
```

目标输出声道数（默认 2 = 立体声）  
```rust
pub const TARGET_CHANNELS: u32 = 2;
```

输出采样率，默认 44100  
```rust
pub sample_rate: u32,
```

输出声道数，默认 2  
```rust
pub channels: u32,
```

ringbuf 缓冲时长（毫秒），默认 280  
```rust
pub buffer_ms: u32,
```

切歌淡入时长（毫秒），0 = 真·无间隙播放，默认 0  
```rust
pub crossfade_ms: u32,
```

输出设备名称，None = 使用系统默认设备  
```rust
pub output_device: Option<String>,
```

音频文件元数据（标题/艺术家/专辑/时长/封面标志）  
```rust
pub use decoder::Metadata;
```

DSP 管线核心类型：默认 PEQ 频段 / 预设 / 管线 / 单段均衡 / 预设名  
```rust
pub use dsp:: { ...
```

---

### `analysis/bpm.rs`

用自相关法检测 BPM  
流程：  
1. 帧能量 onset 包络（半波整流差分）  
2. 自相关，在 60-200 BPM 范围找峰  
```rust
pub fn detect_bpm(samples: &[f32], sample_rate: u32) -> Option<f32> { ...
```

---

### `analysis/key.rs`

返回 (key_name, energy)  
```rust
pub fn detect_key(mono: &[f32], sample_rate: u32) -> (Option<String>, Option<f32>) { ...
```

---

### `analysis/mod.rs` — 音频分析：BPM 检测、调性识别、能量值

每分钟拍数，None 表示未检测到稳定节拍  
```rust
pub bpm: Option<f32>,
```

调性（如 "C", "Gm"），None 表示无法识别  
```rust
pub key: Option<String>,
```

能量值（0~1 左右），基于 RMS 计算  
```rust
pub energy: Option<f32>,
```

从 PCM 样本数据中分析 BPM / 调性 / 能量  
```rust
pub fn analyze_from_samples(
```

---

### `decoder.rs` — 解码器（Symphonia 流式解码 + DSD 文件直解）

交错 PCM f32 样本（L/R/L/R/...）  
```rust
pub samples: Vec<f32>,
```

本帧在音频流中的时间位置（秒）  
```rust
pub pts_secs: f64,
```

输出采样率（通常 44100）  
```rust
pub sample_rate: u32,
```

输出声道数（通常 2）  
```rust
pub channels: u32,
```

用法：`Decoder::start(path, sr, ch, pos, seek) → (rx, handle)`  
```rust
pub struct Decoder { ...
```

解码进度（已输出样本数），可被外部读取  
```rust
pub position: Arc<AtomicU64>,
```

启动后台解码线程。返回 (帧接收器, 解码器句柄)。  
- `path` — 音频文件路径  
- `target_rate` / `target_channels` — 输出重采样目标  
- `position` — 外部可读的解码进度（样本数）  
- `seek_pos` — 可选起始位置（秒）  
```rust
pub fn start(
```

停止后台解码线程  
```rust
pub fn stop(&self) { ...
```

适用于小文件（如音效、短片段）或离线分析。  
```rust
pub fn decode_to_memory(path: &Path, tr: u32, tc: u32) -> Result<Vec<f32>, String> { ...
```

---

### `dsd/convert.rs`

`dsd_rate` — DSD 速率 (DSD64=1, DSD128=2, ...)  
```rust
pub fn convert_channel(dsd_bytes: &[u8], _dsd_rate: DsdRate) -> Vec<f32> { ...
```

`chan_bytes` — 每个声道的 DSD 字节数据  
`dsd_rate` — DSD 速率  
```rust
pub fn convert_channels(chan_bytes: &[&[u8]], dsd_rate: DsdRate) -> Vec<f32> { ...
```

---

### `dsd/mod.rs` — DSD 文件解码（DSF / DFF）

---

### `dsp/biquad.rs` — IIR 双二阶滤波器（Biquad）

用原始系数构造（a0 已归一化为 1）  
```rust
pub fn new(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Self { ...
```

freq 中心频率，sample_rate 采样率，gain_db 增益(dB)，q 品质因数。  
```rust
pub fn peaking(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self { ...
```

---

### `dsp/convolver.rs` — FIR 卷积均衡器

每声道一个独立的 FFTConvolver 实例。  
```rust
pub struct ConvolutionEq { ...
```

创建空卷积器（bypass 状态）  
```rust
pub fn new(channels: usize) -> Self { ...
```

- `path`: .wav 文件路径  
- `block_size`: FFT 分块大小（推荐 256-1024）  
自动处理 Mono/Stereo IR：Mono IR 应用于所有声道，Stereo IR 逐声道匹配。  
```rust
pub fn load_wav(&mut self, path: &str, block_size: usize) -> Result<(), String> { ...
```

---

### `dsp/crossfeed.rs` — Crossfeed（Bauer 算法）

创建 Crossfeed，使用 CMOY 预设  
- `sample_rate`: 采样率（Hz）  
```rust
pub fn new(sample_rate: f32) -> Self { ...
```

---

### `dsp/dither.rs` — 高级抖动器：TPDF + ATH 噪声整形

amp: 抖动幅度（单位：LSB 占比，通常 1.0 LSB）  
bits: 目标位深 (16/24)  
```rust
pub fn new(channels: usize, bits: u32, amp_lsb: f32) -> Self { ...
```

ch: 声道索引  
```rust
pub fn process(&mut self, buf: &mut [f32], ch: usize) { ...
```

---

### `dsp/limiter.rs` — 真峰值限幅器（True-Peak Limiter）

创建限幅器。  
- `channels`: 声道数  
- `threshold_db`: 阈值（dBFS, 0 = 0dBFS, 负值更激进）  
```rust
pub fn new(channels: usize, threshold_db: f32) -> Self { ...
```

---

### `dsp/mod.rs` — DSP 管线模块

---

### `dsp/pipeline.rs` — DSP 管线：串联各滤波器

中心频率（Hz）  
```rust
pub freq: f32,
```

增益（dB，范围通常 ±12）  
```rust
pub gain_db: f32,
```

Q 值（影响带宽，典型 0.5~10）  
```rust
pub q: f32,
```

构造管线。peq_bands: 各段 PEQ 参数；enable_crossfeed: 是否启用串音；  
volume: 0~1；bits: 目标输出位深（抖动用）  
```rust
pub fn new(
```

---

### `dsp/widener.rs` — 立体声展宽 (Mid/Side 处理)

width=1.0 → 原始, width=0.0 → 单声道, width>1.0 → 展宽  
```rust
pub struct StereoWidener { ...
```

创建默认关闭的展宽器  
```rust
pub fn new() -> Self { ...
```

当前展宽系数  
```rust
pub fn width(&self) -> f32 { ...
```

---

### `engine.rs`

使用默认配置启动引擎线程，返回句柄和事件接收器  
```rust
pub fn start() -> (EngineHandle, Receiver<EngineEvent>) { ...
```

设置播放队列并从第一首开始播放  
```rust
pub fn play_queue(&self, paths: Vec<String>) { ...
```

下一首  
```rust
pub fn next_track(&self) { ...
```

暂停播放  
```rust
pub fn pause(&self) { ...
```

恢复播放  
```rust
pub fn resume(&self) { ...
```

停止播放并清空队列  
```rust
pub fn stop(&self) { ...
```

跳转到指定位置（秒）  
```rust
pub fn seek(&self, pos: f64) { ...
```

加载脉冲响应文件（卷积均衡器用）  
```rust
pub fn load_ir(&self, path: String) { ...
```

清除脉冲响应（恢复平坦响应）  
```rust
pub fn clear_ir(&self) { ...
```

设置参数均衡器某频段的参数  
```rust
pub fn set_peq_band(&self, index: usize, band: PeqBand) { ...
```

设置立体声展宽  
```rust
pub fn set_stereo_widener(&self, enabled: bool, width: f32) { ...
```

设置音量（0.0 ~ 2.0）  
```rust
pub fn set_volume(&self, vol: f32) { ...
```

设置 ReplayGain 增益（dB），作为 Pre-amp 在 DSP 管线 HPF 后、EQ 前应用  
```rust
pub fn set_replaygain_gain_db(&self, gain_db: f32) { ...
```

更新引擎配置（采样率/声道/缓冲），下次播放时生效  
```rust
pub fn set_config(&self, config: EngineConfig) { ...
```

设置播放模式（普通 / 单曲循环 / 随机）  
```rust
pub fn set_play_mode(&self, mode: PlayMode) { ...
```

从队列中移除指定索引的曲目  
```rust
pub fn remove_from_queue(&self, index: usize) { ...
```

设置输出设备名称（None = 系统默认），下次播放时生效  
```rust
pub fn set_output_device(&self, name: String) { ...
```

获取当前播放位置（秒）  
```rust
pub fn position_secs(&self) -> f64 { ...
```

获取当前曲目时长（秒），0 表示未知  
```rust
pub fn duration_secs(&self) -> f64 { ...
```

是否正在播放（未暂停）  
```rust
pub fn is_playing(&self) -> bool { ...
```

查询 underrun 计数  
```rust
pub fn underrun_count(&self) -> u64 { ...
```

---

### `output.rs` — 音频输出抽象层

ringbuf 消费者端，回调通过它读取样本  
```rust
pub consumer: Mutex<HeapCons<f32>>,
```

underrun 计数（回调读不到数据时递增）  
```rust
pub underrun_count: AtomicU64,
```

---

### `output/output_cpal.rs` — cpal 音频输出后端

---

> 67 个 pub 项。运行 `bash doc-api.sh` 刷新。
