# wavelink-audio-core HiFi 音频输出方案分析

## 一、项目是什么

wavelink-audio-core 是一个纯 Rust 音频引擎库，约 8000 行代码，提供：

- **解码**：MP3 / FLAC / WAV / AAC / ALAC / Vorbis / Opus / WavPack / DSD / AIFF
- **DSP 管线**：高通滤波 → ReplayGain → 卷积 EQ → 参数均衡器 → Crossfeed → 立体声展宽 → 限幅 → 音量 → 抖动
- **音频分析**：BPM / 调性检测（FFT）
- **元数据**：标签读取、封面提取、ReplayGain 标签
- **播放引擎**：播放队列、播放模式、无缝切歌

编译产物是 staticlib（可嵌入），通过 C FFI 暴露 API（`wavelink_audio_core.h`）。

---

## 二、架构：数据流与分层

```
┌─────────────┐
│  音频文件     │
│  (各种格式)   │
└──────┬──────┘
       │ 解码线程
       ▼
┌─────────────┐
│  DecodedFrame │  数据类型: Vec<f32> 交错 PCM
│  解码 + 混音  │  通道: channel → samples 线性排列 (L/R/L/R/...)
│  + 重采样     │
└──────┬──────┘
       │ crossbeam channel
       ▼
┌─────────────┐
│  Consumer    │  消费线程: DSP 管线处理 + FFT + 抖动 + 变速
│  线程        │
└──────┬──────┘
       │ push_slice(&[f32])
       ▼
┌──────────────────────────────────────────┐
│              Ring Buffer                 │
│            HeapRb<f32>                  │
│                                          │
│  Producer (解码/DSP 侧写入)              │
│  Consumer (音频回调侧读取)               │
│                                          │
│  ← 这是关键分界点 ←                       │
└──────┬───────────────────────────────────┘
       │ pop_slice(&mut [f32])
       ▼
┌──────────────────────────────────────────┐
│         AudioOutput trait               │
│                                          │
│  当前有两个实现:                           │
│                                          │
│  1. AudioOutputCpal ─── cpal 输出        │
│     (桌面端默认，直接驱动物理声卡)          │
│                                          │
│  2. HeadlessOutput ─── 空实现             │
│     (移动端用，ringbuf 数据由外部读取)      │
│         │                                │
│         ▼                                │
│    ac_audio_read()  ← C FFI             │
│    (被 Android Oboe / iOS AudioUnit      │
│     回调持续调用，从 ringbuf 拉取 PCM)      │
└──────────────────────────────────────────┘
```

**关键事实：整个解码和 DSP 管线输出的终点就是 ringbuf。ringbuf 之后怎么送到硬件，完全由 `AudioOutput` trait 的实现决定。**

---

## 三、问题：cpal 对 HiFi 场景的局限

当前桌面端（macOS / Windows）默认使用 **cpal** 作为音频输出后端。cpal 是一个跨平台音频抽象库，设计目标是兼容性而非极致性能。

在 **HiFi 播放器** 场景下，cpal 存在以下问题：

| 需求 | cpal 的表现 |
|---|---|
| **独占模式** (Exclusive Mode) | 不支持。cpal 只能走共享模式，系统 SRP 会重采样音频流。 |
| **ASIO 驱动** | 不支持。Windows HiFi 社区绕不开 ASIO。 |
| **位深精确输出** (16/24/32 bit fixed) | cpal 回调固定交出 `&mut [f32]`，由系统做最终量化，无法保证位深精确。 |
| **DSD 直出 / DoP** | 不支持。没有 DSD over PCM 封装或 Native DSD 路径。 |
| **延迟控制** | cpal 使用默认缓冲区大小，无法精确配置极低延迟。 |
| **采样率切换** | 切歌时可能需要重建 cpal stream，有爆音风险，cpal 本身不处理淡入淡出。 |
| **多设备路由** | 只能选一个设备，无法做多区域输出。 |

---

## 四、为什么这个问题容易解决

**架构上已经做好了分界。**

1. **`AudioOutput` trait 是抽象接口**，只有三个方法：`pause()` / `resume()` / `swap_consumer()`。替换后端只需要实现这个 trait。

2. **`ac_audio_read()` 已经存在**。这是 C FFI 函数，签名如下：

   ```c
   int ac_audio_read(void* engine, float* buffer, int samples);
   // 返回实际读取的样本数。0 = 无数据。
   ```

   它从 ringbuf 消费者端取 PCM 数据填入调用方提供的 `buffer`。Android Oboe 和 iOS AudioUnit 的回调已经在用这个函数。

3. **HeadlessOutput 模式是现成的 fallback**。不启用 cpal 时，引擎自动进入 HeadlessOutput 模式，ringbuf 数据等外部通过 `ac_audio_read()` 消费。桌面端平台原生音频代码接入的就是这个路径。

---

## 五、解决方案

**方案一句话：不替换引擎，只替换 `AudioOutput` trait 的实现。**

### 按平台分别实现

### macOS

用 **Core Audio AudioUnit** 或 **AVAudioEngine** 替代 cpal。

```
macOS 音频回调（RunLoop / RenderCallback）
   │
   ├→ ac_audio_read(engine, buffer, n_frames * 2)
   └→ 填入 AudioUnit 输出 buffer
```

优势：自动采样率切换、独占输出、极低延迟（<5ms）、AirPlay 支持、设备热插拔。

### Windows

用 **WASAPI Exclusive** 或 **ASIO** 替代 cpal。

```
WASAPI 渲染线程 / ASIO callback
   │
   ├→ ac_audio_read(engine, buffer, n_frames * 2)
   └→ 填入 WASAPI buffer 或 ASIO output
```

优势：位深精确控制、ASIO 全托管、无系统混音器干扰、DSD DoP 可做。

### 需要的 Rust 端改动（极小）

`AudioOutput` trait 可能需要增加 1-2 个方法，让外部知道引擎的采样率和缓冲区期望：

```rust
pub trait AudioOutput {
    fn pause(&self);
    fn resume(&self);
    fn swap_consumer(&self, buffer_ms: u32, sample_rate: u32, channels: u32) -> PcmProducer;
    // 可能需要新增:
    // fn sample_rate(&self) -> u32;
    // fn channels(&self) -> u32;
}
```

以及确认当 cpal-backend feature 关闭时，`open()` 返回的 `HeadlessOutput` 已正确注册到全局 `HEADLESS_INNER`（已实现，见 `output.rs:103`）。

### 总结

| | 改动范围 | 工作量估计 |
|---|---|---|
| Rust 引擎代码 | `AudioOutput` trait 加 1-2 个方法 | ~10 行 |
| macOS 原生端 | 新建 AudioUnit 回调 + ac_audio_read 轮询 | ~300 行 Swift/ObjC |
| Windows 原生端 | 新建 WASAPI 线程 + ac_audio_read 轮询 | ~300 行 C++ |
| Android 原生端 | **已经实现**（Oboe + ac_audio_read） | 0 |
| iOS 原生端 | **已经实现**（AudioUnit + ac_audio_read） | 0 |

**核心引擎代码不用动。解码和 DSP 管线完全不变。** 这本质上是在现有架构的最后一层插入平台原生音频驱动，而非重写。
