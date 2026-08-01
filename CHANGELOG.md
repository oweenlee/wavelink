# Changelog

## Unreleased

### 整改（1.0-rc.2 方向）

- **API 收敛**：移除根级重导出（`Metadata`/`read_metadata`/`parse_cue`/`CueSheet` 等），
  下游统一走模块路径 `audio_core::decoder::*`、`audio_core::cue::*`
- **错误类型结构化**：`EngineError` 去掉 `PartialEq`，
  `FileNotFound(PathBuf)`、`DecodeFailed { path, reason }` 携带上下文
- **解码错误传播**：解码线程失败时通过 `bounded::<EngineError>(1)` 旁路通道上报，
  consumer `on_end_of_track` 时检查并转发为 `EngineEvent::Error`
- **consumer 回调 struct 化**：`run_consumer_loop` 从 11 参数收敛为
  `ConsumerCallbacks<'a>` + `ConsumerControl`（stop/ready_tx/speed）
- **测试去 sleep**：consumer 单元测试改用 Condvar/channel 信号等待；
  engine_integration 改用 `wait_for_playing`/`wait_for_position_event` 事件轮询

## 1.0.0-rc.1 (2026-08-01)

1.0 候选版：清理遗留架构，聚焦纯 Rust API。

### 亮点

- 移除无消费者的 FFI / UniFFI 层，对外统一为纯 Rust `EngineHandle`
- 引擎支持运行时切换输出采样率（`SetOutputSampleRate` / `HeadlessOutput`），iOS bit-perfect 地基
- 独占模式跟随选中设备 + Windows WASAPI 独占/共享降级
- 变速音质升级：rubato sinc + Crossfeed 三预设
- ReplayGain peak 防过载，派生 `serde::Serialize`
- dither 位深匹配实际输出 + WASAPI 渲染线程实时优先级
- 多声道 downmix + `decode_to_memory` 保护 + speed 无锁化
- Oboe 真设备枚举 + 自适应缓冲（WavPack 待 symphonia 上游发版，见 pdeljanov/Symphonia#502）
- 端到端信号精度测试（11 个）+ CI 增加 fuzz 与平台后端专项检查
- 10 项代码质量修复（P0~P3），clippy 全门槛转绿

### 提交历史

- `4b461b5` feat(decoder): ReplayGain 派生 serde::Serialize
- `e07662f` chore: 修复 capture.rs 在 headless 构建下的警告
- `ed61023` refactor: 移除无消费者的 FFI / UniFFI 层
- `e2d9b22` feat(audio): 引擎支持运行时设置输出采样率
- `3f97333` feat(audio): HeadlessOutput 支持运行时切换输出采样率
- `1977486` chore: 版本升至 1.0.0-rc.1
- `dbe1b4c` chore: 清理 clippy 警告，CI 全门槛转绿
- `b48f513` feat(audio): 独占模式跟随选中设备 + WASAPI 独占/共享降级
- `ff07049` docs: 刷新 API_REFERENCE.md
- `95e1ee9` fix: ReplayGain peak 防过载
- `01deb3a` fix: dither 位深匹配实际输出 + WASAPI 实时优先级
- `07417e9` feat: 变速音质升级 rubato sinc + Crossfeed 三预设
- `e7b599c` test: 端到端信号精度测试（11 个）
- `3697541` docs: 刷新 API_REFERENCE.md
- `1dfca42` fix: 多声道 downmix + decode_to_memory 保护 + speed 无锁化
- `5c028c1` fix: 10 项代码质量修复（P0~P3）
- `869cb19` feat: Oboe 真设备枚举 + 自适应缓冲；移除 wavpack-rs 待 symphonia 发版
- `6d85fa8` refactor: 抽出 output_setup 纯函数
- `c63106a` chore: HIFI_OUTPUT_ANALYSIS.md 归档 + CI 加 fuzz
- `eba9ba9` ci: 修复 --all-features 失败 + 平台后端专项检查
- `a3c0782` chore: README 默认值修正 + wavpack-rs git rev 锁定 + CHANGELOG

## 0.1.0 (2026-07-27)

初始版本，从 wavelink-engine 独立仓库。

### 亮点

- 纯 Rust 跨端音频引擎（Symphonia 解码 → rubato SRC → DSP 管线 → 输出），零 C 依赖
- 四套输出后端：WASAPI Exclusive (Windows) / AudioUnit (macOS/iOS) / Oboe (Android) / cpal (Linux/跨平台)
- Bit-perfect 播放模式：源采样率/位深精确匹配，DSP 管线完全绕过
- 完整 DSP 管线：DC HPF → ReplayGain → FIR 卷积 EQ → IIR PEQ → Crossfeed → 立体声展宽 → 真峰值限幅 → 音量 → 淡入淡出 → TPDF 抖动
- Gapless 无缝播放：预加载解码 + 消费者线程 chain
- macOS Hog Mode 独占模式
- 设备热插拔检测 + 自动恢复
- ReplayGain 完整链路（标签读取 → DSP Pre-amp → 动态更新）
- 变速播放（0.25x–4.0x）
- 实时电平表 + FFT 频谱
- 录音捕获（Capture API）

### 提交历史

- `8bea82f` 初始化独立仓库
- `9e932c2` README 标注跨端引用说明
- `7838e2d` refactor: 抽取 consumer.rs，修复频谱/crossfade/采样率适配
- `f3d0005` OOM guard + backpressure + CI
- `fd8cf8d` 更新 API_REFERENCE.md
- `df0663f` feat: 变速播放 + 实时电平表 + 录音捕获 + 会话管理
- `957d826` fix: 引擎配置同步、无缝切歌时长更新、PrevTrack
- `9871296` fix: 实时安全加固、设备断开自动恢复、FFI 补全
- `cc8947c` feat: 跨平台 HiFi 架构升级（Phase 1-3）
- `07e190f` test: 标记慢测试为 #[ignore]
- `9eddfeb` feat: 网络流媒体 FFI 接口
- `25df8ad` refactor(ffi): AcEvent 动态缓冲区 + 安全签名
- `56dadb1` docs: 刷新文档 + FFI 迁移指南
- `5d9cf73` fix(ffi): capture_inner 字段化 + 警告修复
- `e85ed6a` fix: prev_track 采样率 + recovery 同步 + underrun
- `a9a2fa5` feat: WASAPI Exclusive + bit-perfect + 设备枚举/决策 + 热插拔
- `bc15b6e` feat: 重构 AudioUnit 后端 macOS HALOutput + 整数直出
- `821d3b8` feat: 重写 Android Oboe 后端 + 整数直出
