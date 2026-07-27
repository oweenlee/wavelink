# Changelog

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
