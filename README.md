# audio-core（wavelink-audio-core）

> 跨端纯 Rust 音频核心。被 `wavelink-engine/sdk` 与 `wavelink_mobile/rust` 以 git tag 依赖。
> 发布新版本见根目录 `../README.md` 的发版顺序。

纯 Rust 音频引擎。零 C 依赖，macOS/Windows/Linux/Android/iOS 均可编译。

```
Symphonia 流式解码 → 声道混音 → rubato SRC → DSP 管线 → cpal 输出
```

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│  解码线程                                                     │
│  Symphonia: mp3/flac/wav/ogg/aac/m4a/aiff/opus               │
│  DSD 直解: dsf/dff (3 级 sinc 降采样)                         │
│  WavPack 直解: wv                                             │
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
│  cpal 音频回调 (硬实时)                                        │
│  Mutex<HeapCons> → 输出到默认设备                               │
│  underrun 检测 + 计数                                          │
│  swap_consumer: seek 时不重建 cpal stream                       │
└──────────────────────────────────────────────────────────────┘
```

## 模块

| 模块 | 说明 |
|------|------|
| `decoder` | Symphonia 流式解码 + DSD + WavPack；rubato 异步 SRC；声道混音；seek；`decode_to_memory` |
| `dsp::biquad` | IIR 双二阶 (RBJ cookbook: peaking/lowpass/highpass/shelving) |
| `dsp::convolver` | FIR 分区卷积 (fft-convolver) |
| `dsp::crossfeed` | Bauer 算法耳机串音模拟 |
| `dsp::widener` | Mid/Side 立体声展宽 |
| `dsp::limiter` | 4x 过采样真峰值限幅 |
| `dsp::dither` | TPDF 抖动 (声道独立噪声序列) |
| `dsp::pipeline` | `DspPipeline` 串联所有滤波器；10 种 EQ 预设；运行时调参 |
| `engine` | Actor 模型引擎线程；队列 + 4 种播放模式 + 无缝预加载 + CUE 分轨虚拟队列 + 交叉淡入 + 实时频谱 + 坏帧保护 |
| `output` | cpal 输出 + `swap_consumer` + 采样率 fallback + underrun 计数 |
| `analysis` | BPM (自相关) + 调性 (Chromagram + Krumhansl-Schmuckler) + 能量 |
| `dsd` | DSD→PCM 转换 (3 级 sinc 降采样) |
| `cue` | CUE 分轨解析 (parse_cue / CueSheet / CueTrack) |
| `playlist` | M3U/M3U8/PLS 播放列表解析 |
| `ffi` | C 导出: 引擎控制 / 曲库查询 / 音频分析 |
| `ffi` (ffi) | C 导出: 引擎控制 / 元数据 / 封面 / 音频分析 / 事件轮询 |

## 配置

```rust
use audio_core::{EngineConfig, EngineHandle};

// 默认: 44100Hz / 2ch / 160ms 缓冲 / 0ms 淡入
let (engine, events) = EngineHandle::start();

// 自定义
let config = EngineConfig {
    sample_rate: 96000,
    channels: 2,
    buffer_ms: 80,
    crossfade_ms: 50,  // 0 = 真无间隙播放
};
let (engine, events) = EngineHandle::start_with_config(config);
```

默认 `44100Hz`，rubato 自动将任何源文件（44.1k~384k）重采样到目标输出率。
`sample_rate` 只在需要绕过重采样（如"高解析模式"设 96000/192000）时修改，且输出设备必须支持。
一般用户不需要改动。

## 功能清单

| 功能 | 状态 |
|------|------|
| **解码** | |
| Symphonia: mp3/flac/wav/ogg/aac/m4a/aiff | ✅ |
| Opus (symphonia-adapter-oporus) | ✅ |
| WavPack (wv) | ✅ |
| DSD (dsf/dff) | ✅ |
| rubato 异步 SRC (-120dB aliasing) | ✅ |
| 声道混音 (多声道→立体声/单声道) | ✅ |
| 流式解码 (1GB+ 文件, 恒定内存) | ✅ |
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
| Seek 复用 cpal 流 (~20ms) | ✅ |
| 可配置采样率/声道/缓冲/淡入 | ✅ |
| 采样率 fallback | ✅ |
| 实时频谱 (16 频段, FFT) | ✅ |
| 坏帧保护 | ✅ |
| underrun 计数 | ✅ |
| **分析** | |
| BPM (自相关, 60-200 BPM) | ✅ |
| 调性 (Chromagram + Krumhansl-Schmuckler) | ✅ |
| 能量 (RMS 对数归一化) | ✅ |
| **CUE 分轨** | |
| CUE 文件解析 (CueSheet / CueFile / CueTrack) | ✅ |
| mm:ss:ff 时间戳转换 | ✅ |
| PREGAP 扣除 | ✅ |
| 引擎 CUE 虚拟队列展开 | ✅ |
| **FFI (C 绑定)** | |
| 引擎创建/销毁/控制 | ✅ |
| 播放控制 (play/play_queue/pause/resume/stop/seek/next) | ✅ |
| DSP 控制 (音量/PEQ/展宽/Crossfeed/ReplayGain/IR) | ✅ |
| 队列 & 播放模式 (Normal/RepeatOne/RepeatAll/Shuffle) | ✅ |
| 事件轮询 (非阻塞, 7 种事件类型) | ✅ |
| 元数据读取 (lofty: title/artist/album/genre/year/track/disc/封面) | ✅ |
| ReplayGain 标签读取 (track/album gain+peak) | ✅ |
| 封面读取 (音频 + MP4 + MKV/WebM 附件) / 释放 | ✅ |
| 音频分析 (BPM/Key/能量) | ✅ |
| 采样率探测 | ✅ |
| 曲库查询 | ✅ |
| 音频分析 (JSON 输出) | ✅ |
| 跨平台 (macOS/Windows/Linux/Android/iOS) | ✅ 编译 |

## 测试

```bash
cargo test -p audio-core    # 109 个测试 (95 单元 + 14 集成)
cargo test -p audio-core -- --ignored  # 含 FFmpeg 依赖的格式验证
```

## 依赖

核心: `symphonia` / `cpal` / `rubato` / `lofty` / `ringbuf` / `crossbeam-channel`

### 为什么没有 FFmpeg

Symphonia 纯 Rust → 零 C 依赖 → 一路编译到所有平台 → 无 FFmpeg GPL 许可问题。
