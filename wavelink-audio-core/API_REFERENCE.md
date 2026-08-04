# wavelink-audio-core API Reference

> Source hash: `084c2f14d64a` | Generated: 2026-08-03 14:04
> AI 助手优先读此文件，而非读 `src/` 源码。若 AI 返回的代码与当前签名不匹配，请重新运行 `bash doc-api.sh`。

## Table of Contents

- **Top-Level**
  - 纯 Rust 跨端音频引擎：解码 / DSP 管线 / 频谱分析 / BPM 调性检测。 (`lib.rs`)
- **Engine**
  - Commands & Events (`engine/command.rs`)
  - EngineHandle (`engine/handle.rs`)
  - 音频引擎模块 (`engine/mod.rs`)
  - Queue Entry (`engine/queue.rs`)
  - Device Recovery (`engine/recovery.rs`)
  - Internal State (`engine/state.rs`)
  - Thread Priority (`engine/thread_priority.rs`)
  - Worker Thread (`engine/worker.rs`)
- **Decoder**
  - 解码器（Symphonia 流式解码 + DSD 文件直解） (`decoder.rs`)
- **Capture**
  - 音频输入捕获抽象层 (`capture.rs`)
- **Consumer (Decode→DSP→Ringbuf)**
  - 平台无关的解码→DSP→ringbuf 循环。 (`consumer.rs`)
- **DSP Pipeline**
  - Biquad Filters (`dsp/biquad.rs`)
  - FIR Convolution EQ (`dsp/convolver.rs`)
  - Crossfeed (`dsp/crossfeed.rs`)
  - Dither & Noise Shaping (`dsp/dither.rs`)
  - True-Peak Limiter (`dsp/limiter.rs`)
  - DSP 管线模块 (`dsp/mod.rs`)
  - Pipeline (`dsp/pipeline.rs`)
  - Speed Changer (`dsp/speed.rs`)
  - Stereo Widener (`dsp/widener.rs`)
- **Output**
  - 音频输出抽象层 (`output.rs`)
  - iOS AudioUnit (`output/output_audiounit.rs`)
  - cpal (Desktop) (`output/output_cpal.rs`)
  - Android Oboe (`output/output_oboe.rs`)
- **Analysis**
  - BPM Detection (`analysis/bpm.rs`)
  - Key Detection (`analysis/key.rs`)
  - 音频分析：BPM 检测、调性识别、能量值 (`analysis/mod.rs`)
- **DSD**
  - Conversion (`dsd/convert.rs`)
  - DSD 文件解码（DSF / DFF） (`dsd/mod.rs`)
- **Stream**
  - 流式音频数据源 (`stream.rs`)
- **CUE**
  - CUE 分轨解析。将 `.cue` 文件解析为音轨列表（含曲名、艺术家、起始时间）。 (`cue/mod.rs`)
- **Playlist**
  - 播放列表解析：M3U / M3U8 / PLS。 (`playlist/mod.rs`)
- **Error**
  - 统一错误类型 (`error.rs`)
- **Exclusive Mode**
  - 独占模式支持 (`exclusive.rs`)
- **Misc**
  - DoP（DSD over PCM）打包 (`dsd/dop.rs`)
  - AutoEQ 耳机校正（基于 AutoEq 社区测量数据） (`dsp/autoeq.rs`)
  - AutoEQ 耳机校正数据（内嵌） (`dsp/autoeq/autoeq_data.rs`)
  - 输出设备设置：复用或打开新 output (`engine/output_setup.rs`)
  - LRC 歌词解析与同步 (`lyric.rs`)
  - macOS CoreAudio 设备枚举 (`output/output_coreaudio.rs`)
  - Windows WASAPI Exclusive 模式输出后端 (`output/output_wasapi.rs`)
  - 元数据标签写入（基于 lofty） (`tag.rs`)

---

## Top-Level

### 纯 Rust 跨端音频引擎：解码 / DSP 管线 / 频谱分析 / BPM 调性检测。 (`lib.rs`)

音频输入捕获抽象层  
```rust
pub mod capture;
```

平台无关的解码→DSP→ringbuf 循环（PC 和 Mobile 共享）  
```rust
pub mod consumer;
```

音频文件解码（Symphonia 流式解码 + DSD 直解）  
```rust
pub mod decoder;
```

DSD（DSF/DFF）格式直解为 PCM  
```rust
pub mod dsd;
```

CUE 分轨解析  
```rust
pub mod cue;
```

DSP 管线：参数均衡器 / 串音补偿 / 立体声展宽 / 限幅 / 抖动  
```rust
pub mod dsp;
```

统一错误类型  
```rust
pub mod error;
```

LRC 歌词解析与同步  
```rust
pub mod lyric;
```

元数据标签写入（lofty）  
```rust
pub mod tag;
```

独占模式（macOS Hog Mode / Windows WASAPI Exclusive）  
```rust
pub mod exclusive;
```

音频引擎（桌面端 cpal / 移动端 HeadlessOutput）  
```rust
pub mod engine;
```

音频输出抽象（cpal / HeadlessOutput）  
```rust
pub mod output;
```

流式音频数据源（网络流媒体解码用，平台层写入字节流）  
```rust
pub mod stream;
```

播放列表解析（M3U / M3U8 / PLS）  
```rust
pub mod playlist;
```

目标输出采样率（默认 44100 Hz），可通过 EngineConfig 覆盖  
```rust
pub const TARGET_SAMPLE_RATE: u32 = 44100;
```

目标输出声道数（默认 2 = 立体声）  
```rust
pub const TARGET_CHANNELS: u32 = 2;
```

DSD 播放模式  
```rust
pub enum DsdMode { ...
```

引擎配置  
```rust
pub struct EngineConfig { ...
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

是否自动匹配文件采样率到输出设备（HiFi 场景建议开启）  
```rust
pub auto_sample_rate: bool,
```

是否请求独占模式（WASAPI Exclusive / macOS Hog Mode）  
```rust
pub exclusive_mode: bool,
```

Bit-perfect 模式：绕过所有 DSP，输出采样率/位深精确匹配源文件  
```rust
pub bit_perfect: bool,
```

DSD 播放模式（默认 ToPcm 转 PCM；Dop 需 DoP DAC）  
```rust
pub dsd_mode: DsdMode,
```

引擎事件 / 引擎句柄 / 播放模式 / 电平数据  
```rust
pub use engine:: { ...
```

统一错误类型  
```rust
pub use error::EngineError;
```

---

## Engine

### Commands & Events (`engine/command.rs`)

命令应答通道类型  
```rust
pub type CmdAck = Option<Sender<Result<(), EngineError>>>;
```

频谱分析数据（16 个频段幅值，0.0~1.0 归一化）  
```rust
pub const SPECTRUM_BANDS: usize = 16;
```

播放模式  
```rust
pub enum PlayMode { ...
```

发给引擎线程的命令  
```rust
pub enum EngineCommand { ...
```

引擎发出的事件（主线程通过 Receiver 收取）  
```rust
pub enum EngineEvent { ...
```

实时音频电平：每帧计算 RMS 和峰值（各声道最大值）  
```rust
pub struct Levels { ...
```

RMS 音量（归一化 0.0~1.0，各声道 RMS 的最大值）  
```rust
pub rms: f32,
```

峰值（归一化 0.0~1.0，各声道绝对值的最大值）  
```rust
pub peak: f32,
```

是否削波（任意样本绝对值 ≥ 1.0）  
```rust
pub clip: bool,
```

### EngineHandle (`engine/handle.rs`)

对外的句柄（Send + Sync）  
```rust
pub struct EngineHandle { ...
```

共享输出内部状态（替代全局 static，供宿主层读取音频数据）  
```rust
pub output_inner: Arc<RwLock<Option<Arc<AudioOutputInner>>>>,
```

使用默认配置启动引擎线程，返回句柄和事件接收器  
```rust
pub fn start() -> (EngineHandle, Receiver<EngineEvent>) { ...
```

使用自定义配置启动引擎线程  
```rust
pub fn start_with_config(config: EngineConfig) -> (EngineHandle, Receiver<EngineEvent>) { ...
```

获取当前音频电平（RMS / 峰值 / 削波标志）  
```rust
pub fn levels(&self) -> Levels { ...
```

开始播放指定路径的音频文件（异步，fire-and-forget）  
```rust
pub fn play(&self, path: String) { ...
```

同步播放（等待引擎确认启动成功）  
```rust
pub fn play_sync(&self, path: String) -> Result<(), EngineError> { ...
```

开始流式播放（网络流媒体用），返回 StreamHandle 供写入数据  
```rust
pub fn play_stream(&self, format_hint: Option<String>, content_length: Option<u64>) -> Result<StreamHandle, EngineError> { ...
```

同步流式播放（等待引擎确认启动成功），返回 StreamHandle  
```rust
pub fn play_stream_sync(&self, format_hint: Option<String>, content_length: Option<u64>) -> Result<StreamHandle, EngineError> { ...
```

设置播放队列并从第一首开始播放  
```rust
pub fn play_queue(&self, paths: Vec<String>) { ...
```

下一首  
```rust
pub fn next_track(&self) { ...
```

上一首（播放超过 3 秒则回到开头，否则切回上一曲）  
```rust
pub fn prev_track(&self) { ...
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

跳转到指定位置（秒，异步）  
```rust
pub fn seek(&self, pos: f64) { ...
```

同步跳转（等待引擎确认 seek 完成）  
```rust
pub fn seek_sync(&self, pos: f64) -> Result<(), EngineError> { ...
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

应用 AutoEQ 耳机校正档案（型号名大小写不敏感，None = 清除恢复平坦）。  
可用型号见 `audio_core::dsp::autoeq::catalog()`。  
应用后 EQ 频段被档案替换，档案 preamp 自动作为前置增益应用。  
```rust
pub fn set_auto_eq(&self, name: Option<&str>) { ...
```

设置 DSD 播放模式（下次播放生效）。  
`DsdMode::Dop` 将 DSD 以 DoP 直出给兼容 DAC；设备不支持时引擎自动回退 PCM 转换。  
```rust
pub fn set_dsd_mode(&self, mode: crate::DsdMode) { ...
```

设置立体声展宽  
```rust
pub fn set_stereo_widener(&self, enabled: bool, width: f32) { ...
```

设置跨馈  
```rust
pub fn set_crossfeed(&self, enabled: bool) { ...
```

设置音量（0.0 ~ 2.0）  
```rust
pub fn set_volume(&self, vol: f32) { ...
```

设置 ReplayGain 增益（dB），作为 Pre-amp 在 DSP 管线 HPF 后、EQ 前应用  
```rust
pub fn set_replaygain_gain_db(&self, gain_db: f32) { ...
```

设置 ReplayGain 真峰值（0~1），增益将被限制为不超过 0dBFS。None = 不限制  
```rust
pub fn set_replaygain_peak(&self, peak: Option<f32>) { ...
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

同步设置输出设备（等待引擎确认）  
```rust
pub fn set_output_device_sync(&self, name: String) -> Result<(), EngineError> { ...
```

设置输出采样率（下次播放生效）。  
移动端 bit-perfect 协调：平台层先把设备设到目标速率（iOS `AVAudioSession.setPreferredSampleRate`）  
并读回实际速率，再调用本方法使引擎输出速率与设备一致。命令走 FIFO 通道，  
只要在同一播放之前发送，必在 play 之前生效。  
```rust
pub fn set_output_sample_rate(&self, rate: u32) { ...
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

设置播放速度（0.25 ~ 4.0），1.0 = 正常  
```rust
pub fn set_speed(&self, speed: f32) { ...
```

启用/禁用 ATH 噪声整形  
```rust
pub fn set_noise_shaping(&self, enabled: bool) { ...
```

启用/禁用真峰值限幅  
```rust
pub fn set_limiter_enabled(&self, enabled: bool) { ...
```

启用/禁用抖动（含噪声整形）  
```rust
pub fn set_dither_enabled(&self, enabled: bool) { ...
```

动态调整输出缓冲时长（毫秒），实时生效。仅在 Oboe 后端受支持。  
```rust
pub fn set_buffer_ms(&self, ms: u32) { ...
```

查询 underrun 计数  
```rust
pub fn underrun_count(&self) -> u64 { ...
```

开始音频输入捕获  
```rust
pub fn start_capture(&self, sample_rate: u32, channels: u32) { ...
```

停止音频输入捕获  
```rust
pub fn stop_capture(&self) { ...
```

音频会话中断开始（如电话呼入），引擎自动暂停播放  
```rust
pub fn session_interruption_began(&self) { ...
```

音频会话中断结束，引擎自动恢复播放  
```rust
pub fn session_interruption_ended(&self) { ...
```

从引擎的 ringbuf 读取交错 PCM 样本（替代全局 read_output_samples）。  
返回实际读取的样本数；若输出未初始化返回 0。  
```rust
pub fn read_samples(&self, buf: &mut [f32]) -> usize { ...
```

### 音频引擎模块 (`engine/mod.rs`)

音频引擎模块

### Queue Entry (`engine/queue.rs`)

显示名称（TrackChanged/QueueChanged 事件用）  
```rust
pub display: String,
```

实际解码的音频文件路径  
```rust
pub audio_file: String,
```

文件内起始偏移（秒）  
```rust
pub start_secs: f64,
```

文件内结束位置（秒），<= 0 表示播放到文件末尾  
```rust
pub end_secs: f64,
```

唯一标识（audio_file + start_secs），用于队列移除时精确匹配  
```rust
pub fn unique_key(&self) -> (&str, u64) { ...
```

### Device Recovery (`engine/recovery.rs`)

设备断开自动恢复逻辑

### Internal State (`engine/state.rs`)

引擎内部运行状态（只存在于引擎线程）  
```rust
pub struct EngineState { ...
```

### Thread Priority (`engine/thread_priority.rs`)

各平台策略：  
- macOS / iOS: QOS_CLASS_USER_INTERACTIVE  
- Android: setpriority(PRIO_PROCESS, 0, -16)  
- Linux: SCHED_FIFO priority 80  
- Windows: THREAD_PRIORITY_TIME_CRITICAL  
失败时仅打印日志，不 panic（非关键路径）。  
```rust
pub fn elevate_audio_thread() { ...
```

### Worker Thread (`engine/worker.rs`)

引擎线程主循环 + 消费者线程

---

## Decoder

### 解码器（Symphonia 流式解码 + DSD 文件直解） (`decoder.rs`)

解码输出的一帧 PCM 数据。  
```rust
pub struct DecodedFrame { ...
```

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

流式解码器。后台线程持续解码，通过 crossbeam channel 逐帧输出。  
用法：`Decoder::start(path, sr, ch, pos, seek, end) → (rx, handle)`    
```rust
pub struct Decoder { ...
```

解码进度（已输出样本数），可被外部读取  
```rust
pub position: Arc<AtomicU64>,
```

取走解码错误（非阻塞）。后台解码线程失败时通过此方法获取具体原因。  
```rust
pub fn take_decode_error(&self) -> Option<EngineError> { ...
```

启动后台解码线程。返回 (帧接收器, 解码器句柄)。  
- `path` — 音频文件路径  
- `target_rate` / `target_channels` — 输出重采样目标  
- `position` — 外部可读的解码进度（样本数）  
- `seek_pos` — 可选起始位置（秒）  
- `end_secs` — 可选结束位置（秒），到达后停止解码（CUE 分轨用）  
```rust
pub fn start(
```

以 DoP（DSD over PCM）方式启动 DSD 解码线程。  
原始 DSD 比特流打包为 DoP PCM（采样率 = DSD 速率 / 16），  
不做 DSD→PCM 转换、不重采样、不过 DSP，交给支持 DoP 的 DAC 还原原生 DSD。  
- `left_justify` — 输出格式为 32-bit 整数时传 true（24-bit 字左对齐），24-bit/浮点传 false  
- `target_channels` — 期望声道数（通常用源文件声道数）  
```rust
pub fn start_dop(
```

停止后台解码线程  
```rust
pub fn stop(&self) { ...
```

从流式数据源启动解码（网络流媒体用）。  
- `source` — 平台层写入字节流的 `StreamMediaSource`  
- `target_rate` / `target_channels` — 输出重采样目标  
- `position` — 外部可读的解码进度  
- `format_hint` — 可选格式提示（如 "mp3", "flac", "aac"），帮助 Symphonia 探测  
```rust
pub fn start_from_stream(
```

将整个音频文件解码到内存，返回交错 PCM f32 样本。  
适用于小文件（如音效、短片段）或离线分析。  
```rust
pub fn decode_to_memory(path: &Path, tr: u32, tc: u32) -> Result<Vec<f32>, String> { ...
```

音频文件元数据  
```rust
pub struct Metadata { ...
```

曲名  
```rust
pub title: Option<String>,
```

艺术家  
```rust
pub artist: Option<String>,
```

专辑名  
```rust
pub album: Option<String>,
```

流派  
```rust
pub genre: Option<String>,
```

发行年份  
```rust
pub year: Option<i32>,
```

音轨号  
```rust
pub track_number: Option<u32>,
```

光盘号  
```rust
pub disc_number: Option<u32>,
```

时长（秒）  
```rust
pub duration_secs: f64,
```

是否含有内嵌封面  
```rust
pub has_cover: bool,
```

采样率（Hz）  
```rust
pub sample_rate: Option<u32>,
```

声道数  
```rust
pub channels: Option<u32>,
```

读取音频文件元数据（标题/艺术家/专辑/流派/年份/音轨号/光盘号/封面/时长）  
```rust
pub fn read_metadata(path: &Path) -> Result<Metadata, String> { ...
```

读取音频文件内嵌封面图（JPEG/PNG 原始字节）  
读取封面图片（JPEG/PNG/WEBP 原始字节）。  
支持音频格式（lofty）以及 MKV/WebM 附件封面。  
```rust
pub fn read_cover(path: &Path) -> Result<Vec<u8>, String> { ...
```

ReplayGain 响度归一化增益值  
```rust
pub struct ReplayGain { ...
```

音轨增益 (dB)，如 -5.23  
```rust
pub track_gain_db: Option<f32>,
```

专辑增益 (dB)，如 -7.14  
```rust
pub album_gain_db: Option<f32>,
```

音轨真峰值，如 0.999969  
```rust
pub track_peak: Option<f32>,
```

专辑真峰值  
```rust
pub album_peak: Option<f32>,
```

从音频文件读取 ReplayGain 标签（REPLAYGAIN_TRACK/ALBUM_GAIN/PEAK）  
```rust
pub fn read_replaygain(path: &Path) -> Result<ReplayGain, String> { ...
```

快速探测音频文件的采样率（不完整解码，只读文件头）  
```rust
pub fn probe_sample_rate(path: &Path) -> Option<u32> { ...
```

快速探测音频文件的位深（不完整解码，只读文件头）  
```rust
pub fn probe_bit_depth(path: &Path) -> Option<u16> { ...
```

判断扩展名是否为 DSD 容器（DSF/DFF）  
```rust
pub fn is_dsd_file(path: &Path) -> bool { ...
```

探测 DSD 文件的原始速率和声道数（只读文件头）。  
返回 `(dsd_rate_hz, channels)`，如 DSD64 立体声 → `(2822400, 2)`。  
非 DSD 文件或打开失败返回 None。  
```rust
pub fn probe_dsd_info(path: &Path) -> Option<(u32, u32)> { ...
```

---

## Capture

### 音频输入捕获抽象层 (`capture.rs`)

捕获缓冲消费者端（供宿主层读取）  
```rust
pub struct CaptureInner { ...
```

捕获数据的环缓冲消费者端  
```rust
pub consumer: Mutex<HeapCons<f32>>,
```

开始捕获。返回 Ok(()) 表示成功。  
cpal::Stream 是 !Send，无法跨线程传递。改为在专用线程内创建并持有 stream，  
通过 channel 信号控制生命周期，避免裸指针。  
```rust
pub fn start_global_capture(sample_rate: u32, channels: u32) -> Result<(), String> { ...
```

停止捕获  
```rust
pub fn stop_global_capture() { ...
```

是否正在捕获  
```rust
pub fn is_capturing() -> bool { ...
```

开始捕获（非 cpal 平台无实际操作，仅置位运行标志）。  
```rust
pub fn start_global_capture(_sample_rate: u32, _channels: u32) -> Result<(), String> { ...
```

停止捕获（非 cpal 平台无实际操作，仅清除运行标志与缓冲）。  
```rust
pub fn stop_global_capture() { ...
```

---

## Consumer (Decode→DSP→Ringbuf)

### 平台无关的解码→DSP→ringbuf 循环。 (`consumer.rs`)

频谱频段数  
```rust
pub const SPECTRUM_BANDS: usize = 16;
```

循环配置  
```rust
pub struct ConsumerConfig { ...
```

输出采样率  
```rust
pub sample_rate: u32,
```

声道数  
```rust
pub channels: u32,
```

每 N 帧做一次频谱 FFT（PC=3, Mobile=4）  
```rust
pub fft_interval: u32,
```

切歌淡入时长（毫秒），0 = 无淡入。仅 PC 用，Mobile 保持 0  
```rust
pub crossfade_ms: u32,
```

解码帧接收超时（毫秒）  
```rust
pub recv_timeout_ms: u64,
```

直通模式（DoP 直出用）：跳过 DSP/频谱/淡入/变速/坏帧检测，  
解码帧逐比特原样推入 ringbuf。  
```rust
pub passthrough: bool,
```

消费者循环回调集合  
```rust
pub struct ConsumerCallbacks<'a> { ...
```

将处理后的样本写入 ringbuf，返回实际写入的样本数  
```rust
pub push_samples: &'a dyn Fn(&[f32]) -> usize,
```

过 DSP 管线，原地修改样本  
```rust
pub process_dsp: &'a dyn Fn(&mut [f32]),
```

16 频段频谱回调，每 `fft_interval` 帧调用一次  
```rust
pub on_spectrum: &'a dyn Fn(&[f32; SPECTRUM_BANDS]),
```

检测到坏帧时回调（全零/NaN）  
```rust
pub on_bad_frame: &'a dyn Fn(),
```

每帧输出后回调，参数为输出样本数（用于进度追踪）  
```rust
pub on_samples_output: &'a dyn Fn(u64),
```

当前解码器结束时回调，返回新解码器可无缝切歌  
```rust
pub on_end_of_track: &'a dyn Fn() -> Option<Receiver<DecodedFrame>>,
```

消费者循环控制信号  
```rust
pub struct ConsumerControl { ...
```

停止信号，设 true 后循环尽快退出  
```rust
pub stop: Arc<AtomicBool>,
```

首帧就绪时发送 true，通知播放器可以起播  
```rust
pub ready_tx: Sender<bool>,
```

共享播放速度（0.25 ~ 4.0），设 1.0 不变速  
```rust
pub speed: Arc<AtomicU32>,
```

平台无关的解码消费循环。  
从 `rx` 接收解码帧，依次过 `process_dsp`、可选 crossfade、坏帧检测、`push_samples`。  
每 `fft_interval` 帧计算一次频谱，通过 `on_spectrum` 回调。  
当 `rx` 断开（曲目播完）时调 `on_end_of_track`：返回新的 rx 继续循环，返回 None 退出。  
```rust
pub fn run_consumer_loop(
```

---

## DSP Pipeline

### Biquad Filters (`dsp/biquad.rs`)

用原始系数构造（a0 已归一化为 1）  
```rust
pub fn new(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Self { ...
```

Peaking EQ（参数均衡，RBJ audio EQ cookbook）。  
freq 中心频率，sample_rate 采样率，gain_db 增益(dB)，q 品质因数（自动防零）。  
```rust
pub fn peaking(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self { ...
```

低通（用于 Crossfeed 的高频截断）  
```rust
pub fn lowpass(freq: f32, sample_rate: f32, q: f32) -> Self { ...
```

高通（DC offset 滤除，~2Hz）  
```rust
pub fn highpass(freq: f32, sample_rate: f32, q: f32) -> Self { ...
```

低频搁架（Low Shelf，RBJ audio EQ cookbook，Q 定义 alpha）。  
freq 拐点频率，gain_db 低频增益，q 控制过渡陡峭度（AutoEQ/EqualizerAPO 约定）。  
```rust
pub fn low_shelf(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self { ...
```

高频搁架（High Shelf，RBJ audio EQ cookbook，Q 定义 alpha）。  
freq 拐点频率，gain_db 高频增益，q 控制过渡陡峭度。  
```rust
pub fn high_shelf(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self { ...
```

处理一个样本（单声道）  
```rust
pub fn process(&mut self, x0: f32) -> f32 { ...
```

原地处理一段样本（单声道）  
```rust
pub fn process_slice(&mut self, buf: &mut [f32]) { ...
```

### FIR Convolution EQ (`dsp/convolver.rs`)

FIR 卷积均衡器  
每声道一个独立的 FFTConvolver 实例。  
```rust
pub struct ConvolutionEq { ...
```

创建空卷积器（bypass 状态）  
```rust
pub fn new(channels: usize) -> Self { ...
```

从 WAV 文件加载脉冲响应  
- `path`: .wav 文件路径  
- `block_size`: FFT 分块大小（推荐 256-1024）  
自动处理 Mono/Stereo IR：Mono IR 应用于所有声道，Stereo IR 逐声道匹配。  
```rust
pub fn load_wav(&mut self, path: &str, block_size: usize) -> Result<(), String> { ...
```

处理交错 PCM 缓冲  
```rust
pub fn process(&mut self, buf: &mut [f32]) { ...
```

是否已加载 IR（非 bypass 状态）  
```rust
pub fn is_active(&self) -> bool { ...
```

### Crossfeed (`dsp/crossfeed.rs`)

Crossfeed 预设参数  
```rust
pub struct CrossfeedConfig { ...
```

低通截止频率 (Hz)  
```rust
pub cutoff_hz: f32,
```

对侧信号衰减 (dB)  
```rust
pub attenuation_db: f32,
```

延迟线时长 (µs)  
```rust
pub delay_us: f32,
```

CMOY 预设（最流行）: 700Hz, -6.0dB, 300µs  
```rust
pub const CMOY: CrossfeedConfig = CrossfeedConfig { ...
```

Chu Moy 预设（CMOY 变体，稍紧凑）: 700Hz, -6.0dB, 250µs  
```rust
pub const CHU_MOY: CrossfeedConfig = CrossfeedConfig { ...
```

Jan Meier 预设（更温和，适合古典）: 650Hz, -9.5dB, 250µs  
```rust
pub const JAN_MEIER: CrossfeedConfig = CrossfeedConfig { ...
```

Bauer 算法跨馈处理器  
```rust
pub struct Crossfeed { ...
```

创建 Crossfeed，使用 CMOY 预设（默认）  
```rust
pub fn new(sample_rate: f32) -> Self { ...
```

创建 Crossfeed，使用自定义配置  
```rust
pub fn with_config(sample_rate: f32, config: CrossfeedConfig) -> Self { ...
```

处理交错立体声缓冲 [L, R, L, R, ...]  
```rust
pub fn process(&mut self, buf: &mut [f32]) { ...
```

### Dither & Noise Shaping (`dsp/dither.rs`)

抖动器  
```rust
pub struct Dither { ...
```

amp: 抖动幅度（单位：LSB 占比，通常 1.0 LSB）  
bits: 目标位深 (16/24)  
```rust
pub fn new(channels: usize, bits: u32, amp_lsb: f32) -> Self { ...
```

启用/禁用 ATH 噪声整形  
```rust
pub fn set_noise_shaping(&mut self, enabled: bool) { ...
```

对单声道缓冲注入抖动（就地）  
ch: 声道索引  
```rust
pub fn process(&mut self, buf: &mut [f32], ch: usize) { ...
```

### True-Peak Limiter (`dsp/limiter.rs`)

创建限幅器。  
- `channels`: 声道数  
- `threshold_db`: 阈值（dBFS, 0 = 0dBFS, 负值更激进）  
```rust
pub fn new(channels: usize, threshold_db: f32) -> Self { ...
```

处理单声道缓冲  
```rust
pub fn process(&mut self, buf: &mut [f32], channel: usize) { ...
```

### DSP 管线模块 (`dsp/mod.rs`)

DSP 管线模块

### Pipeline (`dsp/pipeline.rs`)

DSP 管线，按顺序串联：DC HPF → ReplayGain → 卷积 EQ → PEQ → Crossfeed → 展宽 → 限幅 → 音量 → 淡入淡出 → 抖动  
```rust
pub struct DspPipeline { ...
```

PEQ 滤波器类型  
```rust
pub enum PeqKind { ...
```

单段 PEQ 参数（ISO 频段）。10 段典型配置见 `default_peq_bands()`。  
```rust
pub struct PeqBand { ...
```

中心频率（Hz）；对 shelf 为拐点频率  
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

滤波器类型（默认 Peaking；AutoEQ 耳机校正常用 Shelf）  
```rust
pub kind: PeqKind,
```

构造管线。peq_bands: 各段 PEQ 参数；enable_crossfeed: 是否启用串音；  
volume: 0~1；bits: 目标输出位深（抖动用）  
```rust
pub fn new(
```

运行时启用/关闭 Crossfeed（串音补偿）  
```rust
pub fn set_crossfeed(&mut self, enabled: bool) { ...
```

处理一帧交错 PCM（长度需为 channels 的整数倍）  
```rust
pub fn process(&mut self, buf: &mut [f32]) { ...
```

加载卷积 EQ 的脉冲响应文件  
```rust
pub fn load_conv_ir(&mut self, path: &str) -> Result<(), String> { ...
```

清除卷积 EQ（bypass）  
```rust
pub fn clear_conv_ir(&mut self) { ...
```

运行时更新某段 PEQ 参数（所有声道同步更新）  
```rust
pub fn set_peq_band(&mut self, index: usize, band: &PeqBand, sample_rate: f32) { ...
```

整体替换 PEQ 频段（AutoEQ 耳机校正用）。  
频段数可变；在引擎命令线程调用，非实时路径。  
```rust
pub fn replace_peq_bands(&mut self, bands: &[PeqBand], sample_rate: f32) { ...
```

设置 ReplayGain 增益（dB），作为 Pre-amp 在 HPF 后、EQ 前应用  
```rust
pub fn set_replaygain_db(&mut self, gain_db: f32) { ...
```

运行时调整音量 (0.0 ~ 2.0)，限幅器之后应用  
```rust
pub fn set_volume(&mut self, volume: f32) { ...
```

开始淡入（暂停→恢复时消 pop）  
```rust
pub fn start_fade_in(&mut self, duration_ms: u32) { ...
```

开始淡出（暂停/停止时消 pop）  
```rust
pub fn start_fade_out(&mut self, duration_ms: u32) { ...
```

启用/禁用 ATH 噪声整形（替代 TPDF）  
```rust
pub fn set_noise_shaping(&mut self, enabled: bool) { ...
```

启用/禁用真峰值限幅  
```rust
pub fn set_limiter_enabled(&mut self, enabled: bool) { ...
```

启用/禁用抖动（含噪声整形）  
```rust
pub fn set_dither_enabled(&mut self, enabled: bool) { ...
```

设置立体声展宽  
```rust
pub fn set_stereo_widener(&mut self, enabled: bool, width: f32) { ...
```

绕过所有 DSP 处理（bit-perfect 模式）  
```rust
pub fn set_bypass(&mut self, bypass: bool) { ...
```

返回默认 31 段 ISO PEQ 频段（所有增益 0 dB，flat 响应）  
```rust
pub fn default_peq_bands() -> Vec<PeqBand> { ...
```

音效预设名称（10 种 EQ 预设）  
```rust
pub enum PresetName { ...
```

按预设名称返回对应的 PEQ 频段参数  
```rust
pub fn preset_bands(name: PresetName) -> Vec<PeqBand> { ...
```

### Speed Changer (`dsp/speed.rs`)

变速重采样器（rubato sinc 高质量实现）  
```rust
pub struct SpeedChanger { ...
```

新建变速器，初始速度 1.0（正常）  
```rust
pub fn new() -> Self { ...
```

设置播放速度（0.25 ~ 4.0），速度变化时重建重采样器  
```rust
pub fn set_speed(&mut self, speed: f32) { ...
```

获取当前速度  
```rust
pub fn speed(&self) -> f32 { ...
```

对交错 PCM 做变速重采样。返回的切片引用内部 buffer，下次调用失效。  
```rust
pub fn process<'a>(&'a mut self, input: &'a [f32], channels: usize) -> &'a [f32] { ...
```

### Stereo Widener (`dsp/widener.rs`)

width=1.0 → 原始, width=0.0 → 单声道, width>1.0 → 展宽  
```rust
pub struct StereoWidener { ...
```

创建默认关闭的展宽器  
```rust
pub fn new() -> Self { ...
```

设置展宽系数（0.0 = 单声道, 1.0 = 原始, >1.0 = 展宽）  
```rust
pub fn set_width(&mut self, width: f32) { ...
```

启用/禁用展宽  
```rust
pub fn set_enabled(&mut self, enabled: bool) { ...
```

是否已启用  
```rust
pub fn enabled(&self) -> bool { ...
```

当前展宽系数  
```rust
pub fn width(&self) -> f32 { ...
```

处理交错立体声缓冲 [L, R, L, R, ...]  
```rust
pub fn process(&mut self, buf: &mut [f32]) { ...
```

---

## Output

### 音频输出抽象层 (`output.rs`)

解码端向 ring buffer 推入样本的生产端  
```rust
pub type PcmProducer = HeapProd<f32>;
```

被音频回调和引擎线程共享的内部状态  
```rust
pub struct AudioOutputInner { ...
```

ringbuf 消费者端，回调通过它读取样本  
使用 parking_lot::Mutex：无内核调用，适配实时音频回调线程  
```rust
pub consumer: Mutex<HeapCons<f32>>,
```

underrun 计数（回调读不到数据时递增）  
```rust
pub underrun_count: AtomicU64,
```

音频流是否发生错误（设备断开等），引擎可据此尝试恢复  
```rust
pub stream_failed: AtomicBool,
```

样本格式  
```rust
pub enum SampleFormat { ...
```

设备支持的单个配置（采样率/位深/声道/独占组合）  
```rust
pub struct DeviceConfig { ...
```

采样率 Hz  
```rust
pub sample_rate: u32,
```

位深（有效位）  
```rust
pub bit_depth: u8,
```

声道数  
```rust
pub channels: u16,
```

样本格式  
```rust
pub sample_format: SampleFormat,
```

是否在独占模式下可用  
```rust
pub exclusive: bool,
```

输出设备详细信息  
```rust
pub struct OutputDeviceInfo { ...
```

设备唯一 ID（系统级）  
```rust
pub id: String,
```

显示名称（友好名）  
```rust
pub name: String,
```

是否为系统默认设备  
```rust
pub is_default: bool,
```

是否为 USB 总线设备（DAC 等外置声卡）  
```rust
pub is_usb: bool,
```

支持的配置列表  
```rust
pub configs: Vec<DeviceConfig>,
```

源音频格式（来自当前播放文件）  
```rust
pub struct SourceFormat { ...
```

原文件采样率 Hz  
```rust
pub sample_rate: u32,
```

原文件有效位深  
```rust
pub bit_depth: u8,
```

声道数  
```rust
pub channels: u16,
```

是否为 DSD  
```rust
pub is_dsd: bool,
```

DSD 原始速率（如 2822400）  
```rust
pub dsd_rate: Option<u32>,
```

输出决策结果  
```rust
pub struct OutputDecision { ...
```

目标设备 ID  
```rust
pub device_id: String,
```

实际输出采样率  
```rust
pub sample_rate: u32,
```

实际输出位深  
```rust
pub bit_depth: u8,
```

实际输出样本格式  
```rust
pub sample_format: SampleFormat,
```

是否独占模式  
```rust
pub exclusive: bool,
```

是否需要重采样  
```rust
pub need_resample: bool,
```

是否需要 DoP（DSD over PCM）  
```rust
pub need_dop: bool,
```

决策说明（给 UI 展示）  
```rust
pub reason: String,
```

输出决策错误  
```rust
pub enum OutputError { ...
```

音频输出 trait，各平台后端分别实现  
```rust
pub trait AudioOutput { ...
```

打开输出设备。  
后端选择优先级:  
  1. Windows WASAPI Exclusive（wasapi-backend feature）  
  2. macOS/iOS AudioUnit（audiounit-backend feature，低延迟 + 整数直出）  
  3. Android Oboe/AAudio Exclusive（oboe-backend feature）  
  4. cpal 共享模式（cpal-backend feature，跨平台 fallback）  
  5. HeadlessOutput（ringbuf 无输出设备，纯数据模式）  
`bit_depth` 在 WASAPI、AudioUnit、Oboe 后端用于格式协商，其他后端忽略。  
```rust
pub fn open(
```

列出所有可用输出设备名称  
```rust
pub fn list_device_names() -> Vec<String> { ...
```

枚举所有输出设备（含详细配置信息）  
平台优先级:  
  Windows + wasapi-backend → WASAPI 原生枚举 + 格式探测  
  macOS → CoreAudio 原生枚举 + 采样率探测  
  其他 → cpal 设备名列表  
```rust
pub fn enumerate_devices() -> Vec<OutputDeviceInfo> { ...
```

设备热插拔事件  
```rust
pub enum DeviceEvent { ...
```

设备热插拔监视器。  
通过轮询 [`enumerate_devices()`] 检测设备变化，约 1.2 秒检测一次。  
Drop 时自动停止。  
```rust
pub struct DeviceMonitor { ...
```

获取事件接收端  
```rust
pub fn receiver(&self) -> &crossbeam_channel::Receiver<DeviceEvent> { ...
```

启动设备热插拔监视。  
返回 [`DeviceMonitor`]，通过 `receiver()` 接收设备变化事件。  
```rust
pub fn start_device_monitor() -> DeviceMonitor { ...
```

输出决策入口  
三层决策：完美匹配 → 采样率匹配 → 重采样  
```rust
pub fn decide_output(
```

### iOS AudioUnit (`output/output_audiounit.rs`)

macOS/iOS AudioUnit 音频输出后端

### cpal (Desktop) (`output/output_cpal.rs`)

cpal 音频输出句柄  
```rust
pub struct AudioOutputCpal { ...
```

cpal 音频流句柄  
```rust
pub stream: cpal::Stream,
```

共享内部状态（consumer ringbuf + underrun 计数）  
```rust
pub inner: Arc<AudioOutputInner>,
```

### Android Oboe (`output/output_oboe.rs`)

Oboe 音频输出句柄  
```rust
pub struct AudioOutputOboe { ...
```

---

## Analysis

### BPM Detection (`analysis/bpm.rs`)

流程：  
1. 帧能量 onset 包络（半波整流差分）  
2. 自相关，在 60-200 BPM 范围找峰  
```rust
pub fn detect_bpm(samples: &[f32], sample_rate: u32) -> Option<f32> { ...
```

### Key Detection (`analysis/key.rs`)

检测调性（major/minor + 根音）  
返回 (key_name, energy)  
```rust
pub fn detect_key(mono: &[f32], sample_rate: u32) -> (Option<String>, Option<f32>) { ...
```

### 音频分析：BPM 检测、调性识别、能量值 (`analysis/mod.rs`)

音频分析结果（BPM / 调性 / 能量）  
```rust
pub struct AnalysisResult { ...
```

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

将交织立体声样本下混为单声道  
```rust
pub fn mix_to_mono(samples: &[f32], channels: u32) -> Vec<f32> { ...
```

分析音频文件：解码 → BPM + 调性 + 能量  
```rust
pub fn analyze_file(path: &Path) -> Result<AnalysisResult, String> { ...
```

从 PCM 样本分析 BPM + 调性 + 能量  
从 PCM 样本数据中分析 BPM / 调性 / 能量  
```rust
pub fn analyze_from_samples(
```

---

## DSD

### Conversion (`dsd/convert.rs`)

将单声道 DSD 字节转换为 PCM f32  
`dsd_rate` — DSD 速率 (DSD64=1, DSD128=2, ...)  
```rust
pub fn convert_channel(dsd_bytes: &[u8], _dsd_rate: DsdRate) -> Vec<f32> { ...
```

公开的 stage1 boxcar（供流式解码器调用）  
```rust
pub fn stage1_boxcar_pub(dsd_bytes: &[u8]) -> Vec<f32> { ...
```

流式 FIR 降采样：从 pending 缓冲中取出可计算的输出，保留尾部重叠供下次使用。  
`pending` 包含上次的 FIR 重叠尾部 + 新的 stage1 样本。  
返回本次可输出的 PCM 样本，并将 pending 截断为保留的尾部。  
```rust
pub fn stage2_fir_streaming(pending: &mut Vec<f32>) -> Vec<f32> { ...
```

将多声道 DSD 数据转换为交错 PCM f32  
`chan_bytes` — 每个声道的 DSD 字节数据  
`dsd_rate` — DSD 速率  
```rust
pub fn convert_channels(chan_bytes: &[&[u8]], dsd_rate: DsdRate) -> Vec<f32> { ...
```

获取 DSD 对应的输出采样率  
```rust
pub fn output_sample_rate(dsd_rate: DsdRate) -> u32 { ...
```

### DSD 文件解码（DSF / DFF） (`dsd/mod.rs`)

DoP（DSD over PCM）打包  
```rust
pub mod dop;
```

DSD 解码结果（交错的 PCM f32 样本）  
```rust
pub struct DecodedDsd { ...
```

交错 PCM f32 样本 [L, R, L, R, ...]  
```rust
pub samples: Vec<f32>,
```

声道数  
```rust
pub channels: u32,
```

输出采样率（取决于 DSD 速率）  
```rust
pub sample_rate: u32,
```

从 DSF/DFF 文件解码为 PCM f32（交错）—— 全量解码，仅用于小文件  
```rust
pub fn decode_file(path: &Path) -> Result<DecodedDsd, String> { ...
```

流式 DSD→PCM 解码器。内存占用恒定（约 2×FLUSH_THRESHOLD×channels 字节）。  
```rust
pub struct StreamingDsdDecoder { ...
```

创建流式解码器  
```rust
pub fn new(path: &Path) -> Result<Self, String> { ...
```

获取输出采样率  
```rust
pub fn sample_rate(&self) -> u32 { ...
```

获取声道数  
```rust
pub fn channels(&self) -> usize { ...
```

获取 DSD 速率  
```rust
pub fn dsd_rate(&self) -> DsdRate { ...
```

喂入一个 DSD 块（来自 dsd_iter 的一帧），返回是否达到 flush 阈值  
```rust
pub fn feed(&mut self, chan_frames: &[Box<[u8]>]) -> bool { ...
```

将累积的 DSD 字节转换为交错 PCM f32。可多次调用，内部维护 FIR 重叠状态。  
```rust
pub fn flush(&mut self) -> Vec<f32> { ...
```

最终 flush：处理剩余数据（文件结束时调用）  
```rust
pub fn finalize(&mut self) -> Vec<f32> { ...
```

---

## Stream

### 流式音频数据源 (`stream.rs`)

流式音频数据源（实现 Symphonia `MediaSource`）  
内部通过 crossbeam channel 接收平台层写入的字节数据，  
解码线程以阻塞方式读取。不支持 Seek（网络流不可回溯）。  
```rust
pub struct StreamMediaSource { ...
```

流写入端句柄（平台层持有，通过宿主层写入数据）  
线程安全：可从任意线程调用 write / signal_eof。  
可克隆：克隆后的句柄共享同一个底层 channel。  
```rust
pub struct StreamHandle { ...
```

创建一对 (数据源, 写入句柄)。  
- `content_length`: 可选的 Content-Length（字节），用于进度估算  
```rust
pub fn stream_pair(content_length: Option<u64>) -> (StreamMediaSource, StreamHandle) { ...
```

写入一段音频数据。返回实际写入的字节数。  
如果内部缓冲已满（背压），会阻塞直到解码线程消费。  
如果流已关闭（EOF 或解码器停止），返回 0。  
```rust
pub fn write(&self, data: &[u8]) -> usize { ...
```

通知流结束（EOF）。调用后 write() 将不再生效。  
```rust
pub fn signal_eof(&self) { ...
```

是否已标记 EOF  
```rust
pub fn is_eof(&self) -> bool { ...
```

Content-Length（如果平台层提供了）  
```rust
pub fn content_length(&self) -> Option<u64> { ...
```

---

## CUE

### CUE 分轨解析。将 `.cue` 文件解析为音轨列表（含曲名、艺术家、起始时间）。 (`cue/mod.rs`)

CUE 音轨  
```rust
pub struct CueTrack { ...
```

轨号（如 "01", "02"）  
```rust
pub num: String,
```

曲名  
```rust
pub title: Option<String>,
```

艺术家  
```rust
pub performer: Option<String>,
```

INDEX 01 在音频文件中的起始时间（秒）  
```rust
pub start_secs: f64,
```

PREGAP 时长（秒），虚拟静音，不存在于音频文件中  
```rust
pub pregap_secs: f64,
```

CUE 文件条目（对应一个物理音频文件）  
```rust
pub struct CueFile { ...
```

音频文件路径（CUE 中声明的相对/绝对路径）  
```rust
pub path: String,
```

该文件包含的音轨  
```rust
pub tracks: Vec<CueTrack>,
```

CUE 分轨表顶层结构  
```rust
pub struct CueSheet { ...
```

整碟标题  
```rust
pub title: Option<String>,
```

整碟艺术家  
```rust
pub performer: Option<String>,
```

音频文件列表  
```rust
pub files: Vec<CueFile>,
```

展平所有音轨，返回 `(音频文件路径, 音轨)` 列表  
```rust
pub fn all_tracks(&self) -> Vec<(&str, &CueTrack)> { ...
```

解析 CUE 文件  
```rust
pub fn parse_cue(path: &Path) -> Result<CueSheet, String> { ...
```

从字符串解析 CUE  
```rust
pub fn parse_cue_str(data: &str) -> Result<CueSheet, String> { ...
```

---

## Playlist

### 播放列表解析：M3U / M3U8 / PLS。 (`playlist/mod.rs`)

播放列表条目  
```rust
pub struct PlaylistEntry { ...
```

音频文件路径（已解析为绝对路径或原样保留）  
```rust
pub path: String,
```

曲名（EXTINF / PLS 标题），可能为空  
```rust
pub title: Option<String>,
```

时长（秒，EXTINF / PLS Length），可能为 0  
```rust
pub duration_secs: f64,
```

解析播放列表文件，自动识别 M3U / M3U8 / PLS 格式  
```rust
pub fn parse_playlist(path: &Path) -> Result<Vec<PlaylistEntry>, String> { ...
```

导出 M3U 播放列表  
```rust
pub fn export_m3u(path: &Path, entries: &[PlaylistEntry]) -> Result<(), String> { ...
```

导出 PLS 播放列表  
```rust
pub fn export_pls(path: &Path, entries: &[PlaylistEntry]) -> Result<(), String> { ...
```

根据扩展名自动推导导出格式并写入播放列表  
```rust
pub fn export_playlist(path: &Path, entries: &[PlaylistEntry]) -> Result<(), String> { ...
```

---

## Error

### 统一错误类型 (`error.rs`)

引擎错误类型  
```rust
pub enum EngineError { ...
```

---

## Exclusive Mode

### 独占模式支持 (`exclusive.rs`)

macOS: 获取 Hog Mode（独占指定/默认音频设备）  
设置后其他应用无法使用该设备，直到本进程释放或退出。  
```rust
pub fn acquire_exclusive_mode(device_name: Option<&str>) -> bool { ...
```

macOS: 释放 Hog Mode  
```rust
pub fn release_exclusive_mode(device_name: Option<&str>) { ...
```

Windows: 独占模式由 WASAPI 后端在打开音频流时按流获取  
（IAudioClient::Initialize + AUDCLNT_SHAREMODE_EXCLUSIVE，失败自动降级共享）。  
此处仅报告能力，不做 COM 初始化——COM 生命周期由后端自行管理，避免引用计数失衡。  
```rust
pub fn acquire_exclusive_mode(_device_name: Option<&str>) -> bool { ...
```

Windows: 独占随音频流关闭自动释放，此处无操作  
```rust
pub fn release_exclusive_mode(_device_name: Option<&str>) { ...
```

其他平台：独占模式暂不支持  
```rust
pub fn acquire_exclusive_mode(_device_name: Option<&str>) -> bool { ...
```

其他平台：释放独占模式（无操作）  
```rust
pub fn release_exclusive_mode(_device_name: Option<&str>) { ...
```

---

## Misc

### DoP（DSD over PCM）打包 (`dsd/dop.rs`)

DoP 标记 B（奇数帧）  
```rust
pub const DOP_MARKER_B: u32 = 0xFA;
```

DoP 支持的最大 PCM 速率（DSD256）。DSD512 的 1.4112 MHz 绝大多数 DAC 不支持。  
```rust
pub const MAX_DOP_RATE: u32 = 705_600;
```

由 DSD 原始速率（Hz）计算 DoP 的 PCM 采样率  
```rust
pub fn dop_pcm_rate(dsd_rate_hz: u32) -> u32 { ...
```

判断某 DSD 速率能否走 DoP（不超过 DAC 常见上限）  
```rust
pub fn dop_supported(dsd_rate_hz: u32) -> bool { ...
```

将 24-bit 有符号字编码为管线 f32。  
left_justify=false：右对齐（`word / 2^23`，24-bit 输出设备）；  
left_justify=true：左对齐（`(word << 8) / 2^31`，32-bit 输出设备）。  
```rust
pub fn encode_word(word: i32, left_justify: bool) -> f32 { ...
```

DoP 打包器（维护标记交替相位）  
```rust
pub struct DopPacker { ...
```

创建打包器。left_justify：输出格式为 32-bit 整数时传 true。  
```rust
pub fn new(left_justify: bool) -> Self { ...
```

将各声道的原始 DSD 字节打包为交错 DoP f32，追加到 out。  
每声道每 2 个 DSD 字节产生 1 个 PCM 帧；不足 2 字节的尾部忽略  
（调用方应保证按偶数字节喂入，DSF 块大小 4096 天然满足）。  
返回产生的帧数。  
```rust
pub fn pack(&mut self, chans: &[&[u8]], out: &mut Vec<f32>) -> usize { ...
```

### AutoEQ 耳机校正（基于 AutoEq 社区测量数据） (`dsp/autoeq.rs`)

档案滤波器类型（与 PEQ 的 [`PeqKind`](super::pipeline::PeqKind) 对应）  
```rust
pub enum ProfileFilterKind { ...
```

档案中的单个滤波器  
```rust
pub struct ProfileFilter { ...
```

滤波器类型  
```rust
pub kind: ProfileFilterKind,
```

频率 Hz（shelf 为拐点频率）  
```rust
pub freq: f32,
```

增益 dB  
```rust
pub gain_db: f32,
```

Q 值  
```rust
pub q: f32,
```

耳机佩戴形式  
```rust
pub enum HeadphoneForm { ...
```

耳机校正档案  
```rust
pub struct HeadphoneProfile { ...
```

耳机型号名（与 AutoEq 数据库一致）  
```rust
pub name: &'static str,
```

佩戴形式  
```rust
pub form: HeadphoneForm,
```

建议前置增益 dB（通常为负，用于给正增益滤波器留余量防削峰）  
```rust
pub preamp_db: f32,
```

参数化滤波器列表（按 AutoEq 输出顺序）  
```rust
pub filters: &'static [ProfileFilter],
```

返回全部内嵌档案  
```rust
pub fn catalog() -> &'static [HeadphoneProfile] { ...
```

按型号名查找档案（大小写不敏感）  
```rust
pub fn find_profile(name: &str) -> Option<&'static HeadphoneProfile> { ...
```

模糊搜索档案（型号名包含关键字，大小写不敏感）  
```rust
pub fn search_profiles(keyword: &str) -> Vec<&'static HeadphoneProfile> { ...
```

将档案转换为 PEQ 频段（可直接喂给 `EngineHandle::set_peq_band`）  
```rust
pub fn profile_to_peq_bands(profile: &HeadphoneProfile) -> Vec<super::pipeline::PeqBand> { ...
```

### AutoEQ 耳机校正数据（内嵌） (`dsp/autoeq/autoeq_data.rs`)

AutoEQ 耳机校正数据（内嵌）

### 输出设备设置：复用或打开新 output (`engine/output_setup.rs`)

输出设备设置：复用或打开新 output

### LRC 歌词解析与同步 (`lyric.rs`)

单行歌词  
```rust
pub struct LyricLine { ...
```

出现时间（秒，已含 offset 修正）  
```rust
pub time_secs: f64,
```

歌词文本（已去除首尾空白）  
```rust
pub text: String,
```

解析后的歌词  
```rust
pub struct Lyrics { ...
```

按时间升序排列的歌词行  
```rust
pub lines: Vec<LyricLine>,
```

标题（[ti:]）  
```rust
pub title: Option<String>,
```

歌手（[ar:]）  
```rust
pub artist: Option<String>,
```

专辑（[al:]）  
```rust
pub album: Option<String>,
```

是否为空歌词（无有效行）  
```rust
pub fn is_empty(&self) -> bool { ...
```

二分查找给定时刻（秒）应显示的歌词行索引。  
返回最后一个 time_secs <= secs 的行；若尚未到第一行则 None。  
```rust
pub fn line_at(&self, secs: f64) -> Option<usize> { ...
```

解析 LRC 文本内容  
```rust
pub fn parse_lrc(content: &str) -> Lyrics { ...
```

从文件加载歌词（自动识别 UTF-8；BOM 容错）  
```rust
pub fn load_lrc(path: &Path) -> Result<Lyrics, String> { ...
```

为音频文件查找同名侧载歌词文件。  
依次尝试：`song.flac` → `song.lrc` / `song.Lrc` / `song.LRC` / `song.txt`  
```rust
pub fn find_lrc_file(audio_path: &Path) -> Option<PathBuf> { ...
```

### macOS CoreAudio 设备枚举 (`output/output_coreaudio.rs`)

macOS CoreAudio 设备枚举

### Windows WASAPI Exclusive 模式输出后端 (`output/output_wasapi.rs`)

Windows WASAPI Exclusive 模式输出后端

### 元数据标签写入（基于 lofty） (`tag.rs`)

标签更新请求（`None` = 保持原值不变）  
```rust
pub struct TagUpdate { ...
```

标题  
```rust
pub title: Option<String>,
```

歌手  
```rust
pub artist: Option<String>,
```

专辑  
```rust
pub album: Option<String>,
```

专辑歌手  
```rust
pub album_artist: Option<String>,
```

流派  
```rust
pub genre: Option<String>,
```

备注  
```rust
pub comment: Option<String>,
```

曲目号  
```rust
pub track_number: Option<u32>,
```

总曲目数  
```rust
pub track_total: Option<u32>,
```

碟号  
```rust
pub disc_number: Option<u32>,
```

总碟数  
```rust
pub disc_total: Option<u32>,
```

是否所有字段都为空（无操作）  
```rust
pub fn is_empty(&self) -> bool { ...
```

将标签更新写入文件（原地修改）。  
文件无任何标签时，按容器格式创建主标签（如 MP3→ID3v2、FLAC→VorbisComment）。  
仅写入 `Some` 字段，其余保持原值。  
```rust
pub fn write_tags(path: &Path, update: &TagUpdate) -> Result<(), String> { ...
```

读取文件的常见标签字段（写入前预览 / 回读验证用）  
```rust
pub struct TagInfo { ...
```

标题  
```rust
pub title: Option<String>,
```

歌手  
```rust
pub artist: Option<String>,
```

专辑  
```rust
pub album: Option<String>,
```

专辑歌手  
```rust
pub album_artist: Option<String>,
```

流派  
```rust
pub genre: Option<String>,
```

曲目号  
```rust
pub track_number: Option<u32>,
```

读取文件标签（优先主标签，退而任意标签）  
```rust
pub fn read_tags(path: &Path) -> Result<TagInfo, String> { ...
```

---

> 395 pub items. Run `bash doc-api.sh` to refresh.
