# HiFi 音频输出方案分析（已归档）

> 本文档写于项目早期设计阶段，内容已过时。
> 当前输出后端实现和功能状态请参阅 [README](README.md) 和 [CHANGELOG](CHANGELOG.md)。

## 当时分析的要点及当前状态

| 分析要点 | 当前状态 |
|----------|---------|
| cpal 的局限（独占模式、位深、延迟） | WASAPI Exclusive + AudioUnit + Oboe 三套原生后端已解决 |
| 只有 2 个 AudioOutput 实现 | 现有 5 个后端：WASAPI / AudioUnit / Oboe / cpal / Headless |
| 设备枚举/格式协商 | 已实现跨平台枚举 + `decide_output()` 三层决策 |
| DSD DoP/Native 直出 | 尚未实现，见 CHANGELOG |
| ASIO 支持 | 未计划（WASAPI Exclusive 覆盖多数场景） |
