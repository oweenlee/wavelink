# WaveLink 项目结构

跨端音乐播放器，各端共享同一个纯 Rust 音频核心（本地 path 依赖）。

## 仓库一览

| 目录 | 角色 | 依赖 |
|------|------|------|
| `core/` | **跨端纯音频引擎**：解码 / DSP 管线（含 AutoEQ、房间校正 FIR 生成）/ EngineHandle / 频谱 / 分析 | 无（最底层） |
| `mobile/` | **移动端**（Flutter + Rust FFI） | `core` (path) |
| `desktop/` | **PC 端**（Tauri + Svelte 5），曲库 SDK 内置 | `core` (path) |

CI：`.github/workflows/core-ci.yml`（core 三平台测试 + clippy + fuzz；
GitHub Actions 只读仓库根 `.github/`，勿移入子目录）。

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

## 注意事项

- `core` 的 symphonia 用 git main 分支；根 workspace 以 `[patch.crates-io]`
  统一 symphonia-core 源。**patch 不跨 workspace 继承**：独立 workspace
  （`desktop/src-tauri`、`core/fuzz`）各自声明同款 patch，否则双版本编译冲突。
- `core/vendor/oboe` 是根 workspace 隐式成员（经 path 依赖自动加入），
  有意保留以继承 `[profile]` 优化配置。
