# WaveLink 项目结构

跨端音乐播放器，各端共享同一个纯 Rust 音频核心（本地 path 依赖）。

## 仓库一览

| 目录 | 角色 | 依赖 |
|------|------|------|
| `core/` | **跨端纯音频引擎**：解码 / DSP 管线 / EngineHandle / 频谱 / 分析 | 无（最底层） |
| `mobile/` | **移动端**（Flutter + Rust FFI） | `core` (path) |
| `desktop/` | **PC 端**（Tauri + Svelte 5），曲库 SDK 内置 | `core` (path) |

## 依赖方向（自底向上，无环）

```
core  ← 本地 path
   ↗         ↗
desktop      mobile/rust
（crates/sdk path 引用）  （path 引用）
```

## 开发 & 构建

改 `core/` 源码后，无需任何额外操作，各端下次编译时自动使用最新代码：

```bash
# PC 端
cd desktop && npm run tauri dev         # 自动编译 audio-core
npm run tauri build                     # 同上

# 移动端
cd mobile && flutter run                # Rust 层自动编译 audio-core
```
