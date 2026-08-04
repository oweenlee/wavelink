# SDK — 接口参考

播放器只经此 crate 调用音频引擎，不直接依赖 `audio-core`。

## 依赖

```toml
# src-tauri/Cargo.toml
[dependencies]
sdk = { path = "../sdk" }
```

## 引擎控制

### 启动

```rust
use sdk::{EngineConfig, EngineHandle, EngineEvent, PlayMode};

// 默认 44100Hz / 2ch / 280ms 缓冲
let (engine, events) = EngineHandle::start();

// 自定义配置
let (engine, events) = EngineHandle::start_with_config(EngineConfig {
    sample_rate: 96000,
    channels: 2,
    buffer_ms: 80,
    crossfade_ms: 0,       // 切歌淡入, 0=无间隙
    output_device: None,    // None=系统默认
});
```

### EngineHandle 方法

| 方法 | 说明 |
|------|------|
| `play(path)` | 播放单曲 |
| `play_queue(paths)` | 播放队列 |
| `next_track()` | 下一首 |
| `pause()` / `resume()` | 暂停/恢复 |
| `stop()` | 停止 |
| `seek(pos_secs)` | 跳转，复用 cpal 流 |
| `set_play_mode(mode)` | Normal / RepeatOne / RepeatAll / Shuffle |
| `remove_from_queue(idx)` | 从队列移除，0=当前曲目不允许 |
| `load_ir(path)` / `clear_ir()` | 卷积 IR 加载/清除 |
| `set_peq_band(idx, band)` | 更新 PEQ 参数 |
| `set_stereo_widener(enabled, width)` | 立体声展宽 (MS 处理) |
| `set_volume(vol)` | 音量 0.0~1.5 |
| `set_replaygain_gain_db(gain_db)` | ReplayGain Pre-amp (dB) |
| `set_config(config)` | 更新配置，下次播放生效 |
| `set_output_device(name)` | 切换输出设备，下次播放生效 |
| `position_secs()` | 当前播放位置 (秒) |
| `duration_secs()` | 当前曲目时长 (秒) |
| `is_playing()` | 是否播放中 |
| `underrun_count()` | 缓冲不足计数 |

### EngineEvent

引擎通过 `events: Receiver<EngineEvent>` 推送：

```rust
enum EngineEvent {
    TrackChanged(String),                   // 切歌，附带路径
    PlaybackStopped,                        // 停止
    Position(f64),                          // 进度 (秒)，每 200ms
    DurationSecs(f64),                      // 切歌后推送时长
    Error(String),                          // 错误信息
    QueueChanged(Vec<String>, String),      // (完整队列, 当前路径)
    Spectrum(Vec<f32>),                     // 16 频段频谱 0.0~1.0
}
```

### 常量

```rust
pub const TARGET_SAMPLE_RATE: u32 = 44100;
pub const TARGET_CHANNELS: u32 = 2;
```

## 均衡器

```rust
use sdk::dsp::{default_peq_bands, preset_bands, PeqBand, PresetName};

// 31 段 ISO (flat)
let bands = default_peq_bands();

// 10 种预设
let preset = preset_bands(PresetName::Vocals);

// 更新单段
engine.set_peq_band(0, PeqBand { freq: 100.0, gain_db: -3.0, q: 1.41 });

// 全部预设
PresetName::Flat | Rock | Pop | Dance | Classical | Soft
PresetName::FullBass | FullTreble | Techno | Vocals
```

## 音频输出设备

```rust
use sdk::output::list_device_names;

let devices: Vec<String> = list_device_names();
```

## ReplayGain

```rust
use sdk::library::{analyze_loudness, gain_for_loudness};

// 调用 ffmpeg ebur128 滤波器分析文件响度
let lufs = analyze_loudness("/path/to/file.flac")?;  // e.g. -15.8

// 目标 -14 LUFS (串流标准)，计算推荐增益
let gain_db = gain_for_loudness(lufs);                // e.g. +1.8

// 应用到引擎
engine.set_replaygain_gain_db(gain_db as f32);
```

DSP 管线顺序中 ReplayGain 在 HPF 后、EQ 前作为 Pre-amp 应用，与用户音量独立。

## 音频分析

```rust
use sdk::{analyze_file, analyze_from_samples, AnalysisResult};

let result = analyze_file("/path/to/file.flac")?;

// 或从已有 PCM 样本分析
// let result = analyze_from_samples(&samples, 44100, 2);

// 结果
pub struct AnalysisResult {
    pub bpm: Option<f32>,       // 60~200 BPM
    pub key: Option<String>,    // 调性，如 "C", "Am", "G#m"
    pub energy: Option<f32>,    // 0.0~1.0 归一化能量
}
```

## 曲库

```rust
use sdk::library::{LibraryDb, Scanner, Track};

let db = LibraryDb::open("library.db")?;
Scanner::scan_directory(&db, "/music/path")?;

db.all_tracks(50, 0)?;             // 分页
db.search("keyword", 20, 0)?;      // 搜索
db.artists()?;                      // 艺术家列表
db.albums_by_artist("artist")?;    // 专辑列表
db.tracks_by_album("album")?;      // 曲目列表
db.track_count()?;                 // 总数
db.get_cover(track_id)?;           // 封面 (base64)
```

## 支持的音频格式

MP3 / FLAC / PCM (WAV) / Vorbis (OGG) / AAC / ALAC / MP4 / AIFF / Opus / WavPack / DSD (DSF/DFF)
