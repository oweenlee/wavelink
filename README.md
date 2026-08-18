# WaveLink 项目结构

跨端音乐播放器，各端共享同一个纯 Rust 音频核心（本地 path 依赖）。

## 仓库一览

| 目录 | 角色 | 依赖 |
|------|------|------|
| `core/` | **跨端纯音频引擎**：解码 / DSP 管线（含 AutoEQ、房间校正 FIR 生成）/ EngineHandle / 频谱 / 分析 | 无（最底层） |
| `mobile/` | **移动端**（Flutter + Rust FFI，flutter_rust_bridge） | `core` (path) |
| `desktop/` | **PC 端**（Flutter + Rust FFI，flutter_rust_bridge 2.13.0-beta.5） | `core` (path) |

## 依赖方向（自底向上，无环）

```
core  ← 本地 path
   ↗         ↗
desktop/rust   mobile/rust
（FRB 2.13 + path 引用）   （FRB 2.13 + path 引用）
```

> `desktop/` 本身是 Flutter 工程；其 Rust 桥接层在 `desktop/rust/`
> （crate `wavelink_desktop`），以 `cdylib` 编译为
> `libwavelink_desktop.{dylib,dll,so}`，由 Flutter 经 `flutter_rust_bridge`
> 生成的绑定（`RustLib.init(externalLibrary:)`）加载。桌面音频输出走
> `core` 的 cpal 后端（macOS→AudioUnit、Windows→WASAPI、Linux→ALSA）。
> 两端 Rust 绑定层均用 `flutter_rust_bridge` 2.13.0-beta.5 生成，已统一。

## 开发 & 构建

改 `core/` 源码后，各端下次编译时自动使用最新代码：

```bash
# PC 端（macOS / Windows / Linux）
cd /Users/qin/Desktop/wavelink
cargo build -p wavelink_desktop        # 产出 target/debug/libwavelink_desktop.*
cd desktop
flutter run -d macos                   # 或 -d windows / -d linux
```

> 注意：`flutter run` 需从 `desktop/` 目录启动，以便 FFI 层用 `../target/...`
> 相对路径找到 dylib。改了 Rust 后才需重跑 `cargo build`。

```bash
# 移动端
cd mobile && flutter run                # Rust 层自动编译 audio-core
```

## 注意事项

- `core` 的 symphonia 用 git main 分支；根 workspace 以 `[patch.crates-io]`
  统一 symphonia-core 源。`desktop/rust` 已加入根 workspace `members`，
  自动继承该 patch；若新增独立 workspace 的子项，需各自声明同款 patch，
  否则双版本编译冲突。
- `core/vendor/oboe` 是根 workspace 隐式成员（经 path 依赖自动加入），
  有意保留以继承 `[profile]` 优化配置。
- **DSP 参数语义**：以 `core/src/engine` 的定义为准，两端只透传不改写。
