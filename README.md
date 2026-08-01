# audio-core（wavelink-audio-core）

> 跨端纯 Rust 音频核心。被 `wavelink-engine/sdk` 与 `wavelink_mobile/rust` 以 git tag 依赖。
> 发布新版本见根目录 `../README.md` 的发版顺序。

纯 Rust 音频引擎。零 C 依赖，macOS/Windows/Linux/Android/iOS 均可编译。

```
Symphonia 流式解码 → 声道混音 → rubato SRC → DSP 管线 → 输出 (cpal / WASAPI / AudioUnit / Oboe)
```

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│  解码线程                                                     │
│  Symphonia: mp3/flac/wav/ogg/aac/m4a/aiff/opus               │
│  DSD 直解: dsf/dff (3 级 sinc 降采样)                         │
│  WavPack: wv (待上游 pdeljanov/Symphonia#502 合并)               │
│  rubato 异步重采样 (BlackmanHarris2, -120dB aliasing)          │
│  声道混音: 多声道 → 立体声/单声道                                │
└──────────────┬───────────────────────────────────────────────┘
               │ DecodedFrame { samples: Vec<f32> }
               ▼
┌──────────────────────────────────────────────────────────────┐
│  消费者线程 (Consumer)                                         │
│  ┌─────────────────────────────────────────────────┐         │
│  │ DSPPipeline                                      │         │
│  │ ① DC offset HPF (~2Hz)                         │         │
│  │ ② ReplayGain Pre-amp (EBU R128)                  │         │
│  │ ③ FIR 卷积 EQ (fft-convolver, 加载任意 IR WAV)   │         │
│  │ ④ IIR PEQ (31 段 ISO, RBJ Biquad)               │         │
│  │ ⑤ Crossfeed (Bauer 算法)                         │         │
│  │ ⑥ 立体声展宽 (Mid/Side)                           │         │
│  │ ⑦ 真峰值限幅 (4x 过采样)                          │         │
│  │ ⑧ Volume                                         │         │
│  │ ⑨ TPDF 抖动                                      │         │
│  ├─────────────────────────────────────────────────┤         │
│  │  实时频谱分析 (1024-pt FFT, 16 频段, Hann 窗)     │         │
│  │  交叉淡入 (可配置, 余弦曲线)                       │         │
│  │  坏帧保护 (全零/NaN 跳过)                         │         │
│  └───────────────┬─────────────────────────────────┘         │
│                  │ ringbuf::HeapRb<f32>                       │
└──────────────┬───┘                                            │
               ▼                                                │
┌──────────────────────────────────────────────────────────────┐
│  输出后端 (平台自适应)                                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ cpal     │ │WASAPI    │ │AudioUnit │ │ Oboe     │         │
│  │ (跨平台) │ │ (Win 独) │ │ (mac/iOS)│ │(Android) │         │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘         │
│  Mutex<HeapCons> → 输出到设备                                   │
│  underrun 检测 + 计数 | swap_consumer: seek 不重建 stream        │
│  设备热插拔检测 + 自动恢复 | 独占模式 (Hog / WASAPI Exclusive)    │
└──────────────────────────────────────────────────────────────┘
```

## 模块

| 模块 | 说明 |
|------|------|
| `decoder` | Symphonia 流式解码 + DSD；rubato 异步 SRC；声道混音；seek；`decode_to_memory` (WavPack 待上游 pdeljanov/Symphonia#502) |
| `dsp::biquad` | IIR 双二阶 (RBJ cookbook: peaking/lowpass/highpass/shelving) |
| `dsp::convolver` | FIR 分区卷积 (fft-convolver) |
| `dsp::crossfeed` | Bauer 算法耳机串音模拟 |
| `dsp::widener` | Mid/Side 立体声展宽 |
| `dsp::limiter` | 4x 过采样真峰值限幅 |
| `dsp::dither` | TPDF 抖动 (声道独立噪声序列) |
| `dsp::pipeline` | `DspPipeline` 串联所有滤波器；10 种 EQ 预设；运行时调参 |
| `engine` | Actor 模型引擎线程；队列 + 4 种播放模式 + 无缝预加载 + CUE 分轨虚拟队列 + 交叉淡入 + 实时频谱 + 实时电平 + 变速播放 + 会话管理 + 坏帧保护 + 排他模式状态跟踪 |
| `output` | 多后端输出 (cpal / WASAPI / AudioUnit / Oboe) + `swap_consumer` + 采样率 fallback + underrun 计数 + 设备枚举 + 设备热插拔监视 + 输出决策 |
| `analysis` | BPM (自相关) + 调性 (Chromagram + Krumhansl-Schmuckler) + 能量 |
| `capture` | 音频输入捕获 (cpal 后端, 全局状态管理) |
| `dsd` | DSD→PCM 转换 (3 级 sinc 降采样) |
| `exclusive` | 独占模式：macOS Hog Mode / WASAPI Exclusive |
| `cue` | CUE 分轨解析 (parse_cue / CueSheet / CueTrack) |
| `playlist` | M3U/M3U8/PLS 播放列表解析 |
| `stream` | 网络流媒体数据源：`StreamMediaSource`（Symphonia MediaSource）+ `StreamHandle`，平台层写入字节流，core 解码 |

## 配置

```rust
use audio_core::{EngineConfig, EngineHandle};

// 默认: 44100Hz / 2ch / 280ms 缓冲 / 0ms 淡入
let (engine, events) = EngineHandle::start();

// 自定义
let config = EngineConfig {
    sample_rate: 96000,
    channels: 2,
    buffer_ms: 80,
    crossfade_ms: 50,       // 0 = 真·无间隙播放
    output_device: None,    // None = 系统默认设备
    auto_sample_rate: true, // 自动匹配文件采样率到输出设备
    exclusive_mode: false,  // WASAPI Exclusive / macOS Hog Mode
    bit_perfect: false,     // 绕过 DSP，精确匹配源格式
};
let (engine, events) = EngineHandle::start_with_config(config);
```

默认 `44100Hz`，rubato 自动将任何源文件（44.1k~384k）重采样到目标输出率。
`sample_rate` 只在需要绕过重采样（如"高解析模式"设 96000/192000）时修改，且输出设备必须支持。
一般用户不需要改动。

`bit_perfect: true` 时绕过整个 DSP 管线，输出采样率/位深精确匹配源文件（需输出设备支持）。

`exclusive_mode: true` 请求独占音频设备（macOS Hog Mode / WASAPI Exclusive），其他应用无法播放声音。

## 功能清单

| 功能 | 状态 |
|------|------|
| **解码** | |
| Symphonia: mp3/flac/wav/ogg/aac/m4a/aiff | ✅ |
| Opus (symphonia-adapter-oporus) | ✅ |
| WavPack (wv) | ⏳ 待上游 symphonia 合并 (pdeljanov/Symphonia#502) |
| DSD (dsf/dff) | ✅ |
| rubato 异步 SRC (-120dB aliasing) | ✅ |
| 声道混音 (多声道→立体声/单声道) | ✅ |
| 流式解码 (1GB+ 文件, 恒定内存) | ✅ |
| 网络流媒体播放 (StreamMediaSource) | ✅ |
| 全文件解码到内存 (decode_to_memory) | ✅ |
| NaN/Inf 帧检测跳过 | ✅ |
| **DSP 管线** | |
| DC offset HPF (~2Hz) | ✅ |
| ReplayGain Pre-amp (DSP 管线内, 独立于音量) | ✅ |
| FIR 卷积 EQ (加载 IR WAV) | ✅ |
| IIR PEQ (31 段 ISO, 运行时调参) | ✅ |
| 耳机串音模拟 (Bauer crossfeed) | ✅ |
| 立体声展宽 (Mid/Side) | ✅ |
| 真峰值限幅 (4x 过采样) | ✅ |
| TPDF 抖动 | ✅ |
| 10 种 EQ 预设 (Rock/Pop/Classical/Vocals...) | ✅ |
| 运行时所有参数热切换 | ✅ |
| **引擎** | |
| 播放/暂停/恢复/停止/Seek | ✅ |
| 队列管理 + 4 种播放模式 | ✅ |
| 无缝预加载 + 交叉淡入 | ✅ |
| 变速播放 (0.25x~4.0x) | ✅ |
| Seek 复用 stream (~20ms) | ✅ |
| 可配置采样率/声道/缓冲/淡入/输出设备/独占/bit-perfect | ✅ |
| 采样率 fallback | ✅ |
| 实时频谱 (16 频段, FFT) | ✅ |
| 实时电平表 (RMS/Peak/Clipping) | ✅ |
| 坏帧保护 | ✅ |
| underrun 计数 | ✅ |
| 上一首/下一首 | ✅ |
| Bit-perfect 模式 (绕过 DSP, 精确匹配源格式) | ✅ |
| 独占模式 (macOS Hog / WASAPI Exclusive) | ✅ |
| 设备热插拔检测 + 自动恢复 | ✅ |
| 多后端输出 (cpal / WASAPI / AudioUnit / Oboe) | ✅ |
| 音频输入捕获 (cpal 录音) | ✅ |
| 会话中断管理 (iOS 音频打断) | ✅ |
| **分析** | |
| BPM (自相关, 60-200 BPM) | ✅ |
| 调性 (Chromagram + Krumhansl-Schmuckler) | ✅ |
| 能量 (RMS 对数归一化) | ✅ |
| **CUE 分轨** | |
| CUE 文件解析 (CueSheet / CueFile / CueTrack) | ✅ |
| mm:ss:ff 时间戳转换 | ✅ |
| PREGAP 扣除 | ✅ |
| 引擎 CUE 虚拟队列展开 | ✅ |
| **元数据/探测** | |
| 元数据读取 (lofty: title/artist/album/genre/year/track/disc) | ✅ |
| 封面读取 (音频 + MP4 + MKV/WebM 附件) | ✅ |
| ReplayGain 标签读取 (track/album gain+peak) | ✅ |
| 采样率/位深探测 | ✅ |
| 输出设备枚举 (含格式探测) | ✅ |
| 跨平台 (macOS/Windows/Linux/Android/iOS) | ✅ 编译 |

## 测试

```bash
cargo test -p audio-core    # 219 个测试 (单元 + 集成)
cargo test -p audio-core -- --ignored  # 含 FFmpeg 依赖的格式验证
```

## 依赖

核心: `symphonia` / `cpal` / `rubato` / `lofty` / `ringbuf` / `crossbeam-channel`
平台后端: `WASAPI` (Windows) / `AudioUnit` (macOS/iOS) / `Oboe` (Android) / `coreaudio-sys` (macOS 设备枚举)

### 为什么没有 FFmpeg

Symphonia 纯 Rust → 零 C 依赖 → 一路编译到所有平台 → 无 FFmpeg GPL 许可问题。

## Quick Start

```rust
use audio_core::{EngineHandle, EngineConfig};

// 默认配置启动
let (engine, events) = EngineHandle::start();

// 播放文件（异步）
engine.play("/path/to/audio.flac");

// 事件循环
for event in events {
    match event {
        EngineEvent::Position(secs) => println!("播放位置: {secs}s"),
        EngineEvent::TrackChanged(p) => println!("切歌: {p}"),
        _ => {}
    }
}
```

## 网络流媒体播放

平台层负责网络 I/O，core 只做解码 + DSP + 输出：

```rust
// 1. 启动流式播放（format_hint 可为 None 或 "flac"/"mp3" 等）
let stream = engine.play_stream(Some("flac".into()), None)?;

// 2. 在网络数据回调中写入字节
let n = stream.write(data);

// 3. 数据全部写完
stream.signal_eof();
```

## 输出设备枚举

```rust
use audio_core::output::enumerate_devices;

for dev in enumerate_devices() {
    println!("{}: {}Hz/{}ch", dev.name, dev.sample_rate, dev.channels);
}
```

## API 文档

详细 API 参考见 [`API_REFERENCE.md`](./API_REFERENCE.md)（由 `bash doc-api.sh` 自动生成）。
