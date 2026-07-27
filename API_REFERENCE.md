# wavelink-audio-core API Reference

> Source hash: `8e7a193bce3b` | Generated: 2026-07-27 22:57
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
- **FFI (C Bindings)**
  - C 语言 FFI 绑定。通过 `extern "C"` 导出函数供移动端（Kotlin/Swift）调用。 (`ffi.rs`)
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
  - 输出设备设置：复用或打开新 output (`engine/output_setup.rs`)
  - macOS CoreAudio 设备枚举 (`output/output_coreaudio.rs`)
  - Windows WASAPI Exclusive 模式输出后端 (`output/output_wasapi.rs`)
- **C Header Cross-Reference**

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

音频文件解码（Symphonia 流式解码 + WavPack + DSD）  
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

独占模式（macOS Hog Mode / Windows WASAPI Exclusive）  
```rust
pub mod exclusive;
```

C 语言 FFI 绑定（引擎控制 / 元数据 / 音频分析）  
```rust
pub mod ffi;
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

目标输出采样率（默认 44100 Hz），可通过 EngineConfig 覆盖  
```rust
pub const TARGET_SAMPLE_RATE: u32 = 44100;
```

目标输出声道数（默认 2 = 立体声）  
```rust
pub const TARGET_CHANNELS: u32 = 2;
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

引擎事件 / 引擎句柄 / 播放模式 / 电平数据  
```rust
pub use engine:: { ...
```

统一错误类型  
```rust
pub use error::EngineError;
```

音频文件元数据（标题/艺术家/专辑/时长/封面标志）  
```rust
pub use decoder:: { ...
```

CUE 分轨解析入口及核心类型  
```rust
pub use cue:: { ...
```

播放列表解析（M3U / M3U8 / PLS）  
```rust
pub mod playlist;
```

DSP 管线核心类型：默认 PEQ 频段 / 预设 / 管线 / 单段均衡 / 预设名  
```rust
pub use dsp:: { ...
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

当前播放位置（样本数），外部可读  
```rust
pub position: Arc<AtomicU64>,
```

共享输出内部状态（替代全局 static，供 FFI 层读取音频数据）  
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

开始流式播放（网络流媒体用，异步）  
```rust
pub fn play_stream(&self, format_hint: Option<String>, content_length: Option<u64>) { ...
```

同步流式播放（等待引擎确认启动成功）  
```rust
pub fn play_stream_sync(&self, format_hint: Option<String>, content_length: Option<u64>) -> Result<(), EngineError> { ...
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

## FFI (C Bindings)

### C 语言 FFI 绑定。通过 `extern "C"` 导出函数供移动端（Kotlin/Swift）调用。 (`ffi.rs`)

FFI 统一错误码（所有 FFI 函数返回值）  
```rust
pub enum AcError { ...
```

引擎事件  
字符串字段（path）通过调用方提供的缓冲区传出，不再固定长度。  
调用方在调用 ac_engine_poll_event 前设置 path / path_cap，  
函数填充后设置 path_len 为实际需要的长度（不含 null 终止符）。  
```rust
pub struct AcEvent { ...
```

事件类型：0=TrackChanged, 1=PlaybackStopped, 2=Position,  
3=DurationSecs, 4=Error, 5=QueueChanged, 6=Spectrum, 7=Levels  
```rust
pub event_type: c_int,
```

字符串输出缓冲区（调用方分配）  
```rust
pub path: *mut c_char,
```

缓冲区容量（含 null 终止符位置）  
```rust
pub path_cap: c_int,
```

实际字符串长度（不含 null 终止符）；若 >= path_cap 表示缓冲区不足  
```rust
pub path_len: c_int,
```

时间值（Position / DurationSecs）  
```rust
pub value: c_double,
```

频谱 16 频段（Spectrum）  
```rust
pub spectrum: [c_float; 16],
```

音频元数据  
字符串字段通过调用方提供的缓冲区传出。  
调用前设置各字段的 ptr/cap，函数填充后设置 len。  
若 len >= cap 表示缓冲区不足，字符串已被截断。  
```rust
pub struct AcMetadata { ...
```

曲名缓冲区（调用方分配）  
```rust
pub title: *mut c_char,
```

艺术家缓冲区  
```rust
pub artist: *mut c_char,
```

专辑名缓冲区  
```rust
pub album: *mut c_char,
```

流派缓冲区  
```rust
pub genre: *mut c_char,
```

发行年份（0=未知）  
```rust
pub year: c_int,
```

音轨号（0=未知）  
```rust
pub track_number: c_int,
```

光盘号（0=未知）  
```rust
pub disc_number: c_int,
```

时长（秒）  
```rust
pub duration_secs: c_double,
```

是否含有内嵌封面  
```rust
pub has_cover: c_int,
```

音频分析结果（BPM / 调性 / 能量）（BPM / 调性 / 能量）  
```rust
pub struct AcAnalysis { ...
```

BPM 值（0 = 未检测到）  
```rust
pub bpm: c_float,
```

调性字符串，如 "C"/"Gm"，空串 = 无法识别  
```rust
pub key: [c_char; 16],
```

能量值（0~1）  
```rust
pub energy: c_float,
```

实时音频电平  
```rust
pub struct AcLevels { ...
```

RMS 音量（归一化 0.0~1.0）  
```rust
pub rms: c_float,
```

峰值（归一化 0.0~1.0）  
```rust
pub peak: c_float,
```

是否削波（1 = 削波，0 = 正常）  
```rust
pub clip: c_int,
```

事件回调函数类型  
- `event`: 指向事件数据的指针（仅在回调执行期间有效）  
- `user_data`: 调用方自定义上下文指针  
```rust
pub type AcEventCallback = extern "C" fn(event: *const AcEvent, user_data: *mut c_void);
```

引擎不透明句柄（FFI 层内部使用）  
```rust
pub struct AcEngine { ...
```

创建引擎实例。返回不透明指针，失败返回 null。  
output_device 传空串或 null 使用系统默认设备。  
```rust
pub unsafe extern "C" fn ac_engine_create(
```

销毁引擎实例  
```rust
pub unsafe extern "C" fn ac_engine_destroy(engine: *mut c_void) { ...
```

播放指定文件。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_play(engine: *mut c_void, path: *const c_char) -> c_int { ...
```

播放一组文件（替换当前队列）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_play_queue(
```

暂停播放。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_pause(engine: *mut c_void) -> c_int { ...
```

恢复播放。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_resume(engine: *mut c_void) -> c_int { ...
```

停止播放。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_stop(engine: *mut c_void) -> c_int { ...
```

跳转到指定位置（秒）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_seek(engine: *mut c_void, seconds: c_double) -> c_int { ...
```

下一首。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_next_track(engine: *mut c_void) -> c_int { ...
```

上一首（播放>3s 回开头，≤3s 切上一曲）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_prev_track(engine: *mut c_void) -> c_int { ...
```

设置播放模式：0=Normal, 1=RepeatOne, 2=RepeatAll, 3=Shuffle。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_play_mode(engine: *mut c_void, mode: c_int) -> c_int { ...
```

从队列中移除指定位置（0-indexed）的曲目。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_remove_from_queue(engine: *mut c_void, index: c_int) -> c_int { ...
```

设置音量（0.0 ~ 1.0）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_volume(engine: *mut c_void, volume: c_float) -> c_int { ...
```

设置 ReplayGain 增益（dB），0 = 关闭 ReplayGain。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_replaygain_gain(engine: *mut c_void, gain_db: c_float) -> c_int { ...
```

设置 PEQ 单段参数（31 段 ISO 频段）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_peq_band(
```

设置立体声展宽（enabled=0 关闭, width=1.0 原始, >1.0 展宽）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_stereo_widener(
```

加载 IR 文件（FIR 卷积 EQ）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_load_ir(engine: *mut c_void, path: *const c_char) -> c_int { ...
```

清除已加载的 IR。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_clear_ir(engine: *mut c_void) -> c_int { ...
```

切换输出设备（移动端 Headless 模式无效）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_output_device(engine: *mut c_void, name: *const c_char) -> c_int { ...
```

开始音频输入捕获。sample_rate / channels 为目标格式。  
返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_start_capture(
```

停止音频输入捕获。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_stop_capture(engine: *mut c_void) -> c_int { ...
```

从捕获缓冲读取 PCM 样本（与 ac_audio_read 对称）。  
返回实际读取的样本数，0 表示无数据或失败。  
```rust
pub unsafe extern "C" fn ac_audio_read_capture(engine: *mut c_void, buffer: *mut c_float, samples: c_int) -> c_int { ...
```

音频会话中断开始（如电话呼入、其他 App 占用了音频），引擎自动暂停播放。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_session_interruption_began(engine: *mut c_void) -> c_int { ...
```

音频会话中断结束，引擎自动恢复播放。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_session_interruption_ended(engine: *mut c_void) -> c_int { ...
```

从引擎的 ringbuf 读取 PCM 样本。  
buffer: 调用方分配的 float 缓冲区  
samples: 期望读取的样本数（stereo 每帧=2 样本）  
返回: 实际读取的样本数（0 = 无数据）  
```rust
pub unsafe extern "C" fn ac_audio_read(
```

获取当前播放位置（秒）  
```rust
pub unsafe extern "C" fn ac_engine_position(engine: *const c_void) -> c_double { ...
```

获取当前曲目时长（秒）  
```rust
pub unsafe extern "C" fn ac_engine_duration(engine: *const c_void) -> c_double { ...
```

设置播放速度（0.25 ~ 4.0），1.0 = 正常。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_set_speed(engine: *mut c_void, speed: c_float) -> c_int { ...
```

获取播放状态（1=正在播放, 0=未播放）  
```rust
pub unsafe extern "C" fn ac_engine_is_playing(engine: *const c_void) -> c_int { ...
```

获取 underrun 计数  
```rust
pub unsafe extern "C" fn ac_engine_underrun_count(engine: *const c_void) -> c_uint { ...
```

获取实时音频电平（RMS / 峰值 / 削波标志）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_levels(
```

轮询一个引擎事件。返回 1 表示有事件写入 out，0 表示无事件。  
```rust
pub unsafe extern "C" fn ac_engine_poll_event(
```

设置事件回调函数。  
设置后，引擎事件将通过回调函数推送，无需轮询。  
传 callback = null 则禁用回调，恢复轮询模式。  
**重要：** 回调与轮询共享同一个事件 channel，事件会被其中一个消费者取走。  
设置回调后不应再调用 ac_engine_poll_event，否则事件会被随机分配到其中一个。  
注意：回调在独立监听线程中调用，回调函数必须是线程安全的。  
回调中的 event 指针仅在回调执行期间有效，不要保存或跨线程传递。  
```rust
pub unsafe extern "C" fn ac_engine_set_event_callback(
```

读取音频文件元数据。返回 AcError。  
调用前需设置 meta 中各字符串字段的 ptr/cap，函数填充后设置 len。  
```rust
pub unsafe extern "C" fn ac_metadata_read(path: *const c_char, meta: *mut AcMetadata) -> c_int { ...
```

读取内嵌封面图像。返回原始字节（JPEG/PNG），调用方需用 ac_cover_free 释放。  
成功时写入 out_data 和 out_len，返回 AcError_Ok。失败返回对应错误码。  
```rust
pub unsafe extern "C" fn ac_cover_read(
```

释放 ac_cover_read 返回的封面数据  
```rust
pub unsafe extern "C" fn ac_cover_free(data: *mut u8, len: c_int) { ...
```

读取 ReplayGain 标签。返回 AcError。  
track_gain_db / album_gain_db 为 dB 值（如 -5.23），无标签时为 0.0。  
has_track_gain / has_album_gain 指示对应值是否有效。  
```rust
pub unsafe extern "C" fn ac_replaygain_read(
```

分析音频文件（BPM / 调性 / 能量）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_analyze_file(
```

快速探测音频文件采样率。返回采样率 Hz，失败返回 0。  
```rust
pub unsafe extern "C" fn ac_probe_sample_rate(path: *const c_char) -> c_int { ...
```

列出可用输出设备名称。返回设备数量。  
out_buf: 连续存储缓冲区，每个设备名占 name_size 字节（含 null 终止符）。  
max_count: 最多写入的设备数。仅 cpal 后端有效，其他平台返回 0。  
```rust
pub unsafe extern "C" fn ac_list_output_devices(
```

开始流式播放。平台层负责网络 I/O，通过 ac_stream_write 写入数据。  
format_hint 为格式提示（如 "mp3", "flac", "aac"），传 null 则自动探测。  
返回 AcError。  
```rust
pub unsafe extern "C" fn ac_engine_play_stream(
```

向流式播放写入音频数据。应在 ac_engine_play_stream 成功后调用。  
返回实际写入的字节数，0 表示流已关闭或失败。  
```rust
pub unsafe extern "C" fn ac_stream_write(
```

通知流式播放数据已结束（EOF）。返回 AcError。  
```rust
pub unsafe extern "C" fn ac_stream_eof(engine: *mut c_void) -> c_int { ...
```

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

启动后台解码线程。返回 (帧接收器, 解码器句柄)。  
- `path` — 音频文件路径  
- `target_rate` / `target_channels` — 输出重采样目标  
- `position` — 外部可读的解码进度（样本数）  
- `seek_pos` — 可选起始位置（秒）  
- `end_secs` — 可选结束位置（秒），到达后停止解码（CUE 分轨用）  
```rust
pub fn start(
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

---

## Capture

### 音频输入捕获抽象层 (`capture.rs`)

捕获缓冲消费者端（供 FFI 读取）  
```rust
pub struct CaptureInner { ...
```

捕获数据的环缓冲消费者端  
```rust
pub consumer: Mutex<HeapCons<f32>>,
```

开始捕获。返回 Ok(true) 表示成功。  
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

平台无关的解码消费循环。  
从 `rx` 接收解码帧，依次过 `process_dsp`、可选 crossfade、坏帧检测、`push_samples`。  
每 `fft_interval` 帧计算一次频谱，通过 `on_spectrum` 回调。  
当 `rx` 断开（曲目播完）时调 `on_end_of_track`：返回新的 rx 继续循环，返回 None 退出。  
# 参数  
- `rx` — 解码帧接收器  
- `config` — 采样率、声道数、FFT 间隔、crossfade 等配置  
- `push_samples` — 将处理后的样本写入 ringbuf，返回实际写入的样本数  
- `process_dsp` — 过 DSP 管线，原地修改样本  
- `on_spectrum` — 16 频段频谱回调，每 `fft_interval` 帧调用一次  
- `on_bad_frame` — 检测到坏帧时回调（全零/NaN）  
- `on_samples_output` — 每帧输出后回调，参数为输出样本数（用于进度追踪）  
- `on_end_of_track` — 当前解码器结束时回调，返回新解码器可无缝切歌  
- `stop` — 停止信号，设 true 后循环尽快退出  
- `ready_tx` — 首帧就绪时发送 true，通知播放器可以起播  
- `speed` — 共享播放速度（0.25 ~ 4.0），设 1.0 不变速  
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

Bauer 算法跨馈处理器  
```rust
pub struct Crossfeed { ...
```

创建 Crossfeed，使用 CMOY 预设  
- `sample_rate`: 采样率（Hz）  
```rust
pub fn new(sample_rate: f32) -> Self { ...
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

真峰值限幅器。使用 4x 过采样检测采样间峰值（ISP），防止 DAC 重建削波。  
```rust
pub struct TruePeakLimiter { ...
```

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

单段 PEQ 参数（ISO 频段）。10 段典型配置见 `default_peq_bands()`。  
```rust
pub struct PeqBand { ...
```

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

设置 ReplayGain 增益（dB），作为 Pre-amp 在 HPF 后、EQ 前应用  
```rust
pub fn set_replaygain_db(&mut self, gain_db: f32) { ...
```

运行时调整音量 (0.0 ~ 1.5)，限幅器之后应用  
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

新建变速器，初始速度 1.0（正常）  
```rust
pub fn new() -> Self { ...
```

设置播放速度（0.25 ~ 4.0）  
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

流写入端句柄（平台层持有，通过 FFI 写入数据）  
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

macOS: 获取 Hog Mode（独占音频设备）  
设置后其他应用无法使用该设备，直到本进程释放或退出。  
```rust
pub fn acquire_exclusive_mode() -> bool { ...
```

macOS: 释放 Hog Mode  
```rust
pub fn release_exclusive_mode() { ...
```

Windows: WASAPI Exclusive 模式初始化 COM  
注意：实际独占模式获取发生在 IAudioClient::Initialize 中，  
此处仅初始化 COM，确保 WASAPI FFI 可以正常工作。  
```rust
pub fn acquire_exclusive_mode() -> bool { ...
```

Windows: 释放 COM  
```rust
pub fn release_exclusive_mode() { ...
```

其他平台：独占模式暂不支持  
```rust
pub fn acquire_exclusive_mode() -> bool { ...
```

其他平台：释放独占模式（无操作）  
```rust
pub fn release_exclusive_mode() { ...
```

---

## Misc

### 输出设备设置：复用或打开新 output (`engine/output_setup.rs`)

输出设备设置：复用或打开新 output

### macOS CoreAudio 设备枚举 (`output/output_coreaudio.rs`)

macOS CoreAudio 设备枚举

### Windows WASAPI Exclusive 模式输出后端 (`output/output_wasapi.rs`)

Windows WASAPI Exclusive 模式输出后端

---

## C Header Cross-Reference

`include/wavelink_audio_core.h` declares 43 functions and 6 types;
`src/ffi.rs` defines 43 exported functions and 7 types.

FFI layer and C header are fully in sync.

---

> 367 pub items (43 FFI exports). Run `bash doc-api.sh` to refresh.
