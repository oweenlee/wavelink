# wavelink-audio-core API Reference

> 源码 hash: `7441815421dd`  |  生成时间: 2026-07-20 23:51
> AI 助手优先读此文件，而非读 `src/` 源码。若 AI 返回的代码与当前签名不匹配，请重新运行 `bash doc-api.sh`。

---

### `lib.rs` — 纯 Rust 跨端音频引擎：解码 / DSP 管线 / 频谱分析 / BPM 调性检测。

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

音频输出抽象（cpal / HeadlessOutput）  
```rust
pub mod output;
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

### `consumer.rs` — 平台无关的解码→DSP→ringbuf 循环。

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
```rust
pub fn run_consumer_loop(
```

---

### `cue/mod.rs` — CUE 分轨解析。将 `.cue` 文件解析为音轨列表（含曲名、艺术家、起始时间）。

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

音频文件路径（CUE 中声明的相对/绝对路径）  
```rust
pub path: String,
```

该文件包含的音轨  
```rust
pub tracks: Vec<CueTrack>,
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

适用于小文件（如音效、短片段）或离线分析。  
```rust
pub fn decode_to_memory(path: &Path, tr: u32, tc: u32) -> Result<Vec<f32>, String> { ...
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

读取封面图片（JPEG/PNG/WEBP 原始字节）。  
支持音频格式（lofty）以及 MKV/WebM 附件封面。  
```rust
pub fn read_cover(path: &Path) -> Result<Vec<u8>, String> { ...
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

---

### `dsd/convert.rs`

`dsd_rate` — DSD 速率 (DSD64=1, DSD128=2, ...)  
```rust
pub fn convert_channel(dsd_bytes: &[u8], _dsd_rate: DsdRate) -> Vec<f32> { ...
```

`pending` 包含上次的 FIR 重叠尾部 + 新的 stage1 样本。  
返回本次可输出的 PCM 样本，并将 pending 截断为保留的尾部。  
```rust
pub fn stage2_fir_streaming(pending: &mut Vec<f32>) -> Vec<f32> { ...
```

`chan_bytes` — 每个声道的 DSD 字节数据  
`dsd_rate` — DSD 速率  
```rust
pub fn convert_channels(chan_bytes: &[&[u8]], dsd_rate: DsdRate) -> Vec<f32> { ...
```

---

### `dsd/mod.rs` — DSD 文件解码（DSF / DFF）

创建流式解码器  
```rust
pub fn new(path: &Path) -> Result<Self, String> { ...
```

获取声道数  
```rust
pub fn channels(&self) -> usize { ...
```

获取 DSD 速率  
```rust
pub fn dsd_rate(&self) -> DsdRate { ...
```

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

### `ffi.rs` — C 语言 FFI 绑定。通过 `extern "C"` 导出函数供移动端（Kotlin/Swift）调用。

event_type: 0=TrackChanged, 1=PlaybackStopped, 2=Position,  
            3=DurationSecs, 4=Error, 5=QueueChanged, 6=Spectrum  
```rust
pub struct AcEvent { ...
```

曲目路径 / 错误消息  
```rust
pub path: [c_char; 1024],
```

时间值（Position / DurationSecs）  
```rust
pub value: c_double,
```

频谱 16 频段（Spectrum）  
```rust
pub spectrum: [c_float; 16],
```

曲名  
```rust
pub title: [c_char; 512],
```

艺术家  
```rust
pub artist: [c_char; 512],
```

专辑名  
```rust
pub album: [c_char; 512],
```

流派  
```rust
pub genre: [c_char; 128],
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

output_device 传空串或 null 使用系统默认设备。  
```rust
pub unsafe extern "C" fn ac_engine_create(
```

buffer: 调用方分配的 float 缓冲区  
samples: 期望读取的样本数（stereo 每帧=2 样本）  
返回: 实际读取的样本数（0 = 无数据）  
```rust
pub unsafe extern "C" fn ac_audio_read(
```

成功时写入 out_data 和 out_len，返回 0。失败返回非 0。  
```rust
pub unsafe extern "C" fn ac_cover_read(
```

track_gain_db / album_gain_db 为 dB 值（如 -5.23），无标签时为 0.0。  
has_track_gain / has_album_gain 指示对应值是否有效。  
```rust
pub unsafe extern "C" fn ac_replaygain_read(
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

桌面端（cpal-backend feature）优先使用 cpal 后端连接物理设备；  
若 cpal 不可用或未启用 feature，回退到 HeadlessOutput（ringbuf 无输出设备）。  
```rust
pub fn open(
```

---

### `output/output_cpal.rs` — cpal 音频输出后端

---

### `playlist/mod.rs` — 播放列表解析：M3U / M3U8 / PLS。

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

---

> 128 个 pub 项。运行 `bash doc-api.sh` 刷新。
