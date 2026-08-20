# WaveLink Mobile

WaveLink 移动端播放器（Android + iOS），与桌面端共享 [audio-core](../core) 音频引擎。

## 功能特性

- **多音乐源**：NAS/SMB、WebDAV、Subsonic、本地导入、Apple Music，STRM 指针文件（含跨源解析）；NAS 支持多配置档案保存与切换（切换/删除时自动清理旧曲库）
- **播放缓存与断点续播**：播放时自动缓存（SMB 边下边播落盘、WebDAV 整曲下载、Subsonic 流式），重启后恢复上次队列与进度；设置内可一键清理无引用的缓存（封面/下载/歌词）
- **音质增强**：EQ + 自动调音（AutoEQ）、房间校正（REW 曲线生成 FIR 滤波器应用到 DSP）、耳机校正
- **歌词**：LRC 解析与滚动歌词，远端歌词支持 GBK 解码；播放历史与「最近播放」列表（SQLite 持久化）
- **多语言**：中文 / English / 日本語 / 한국어 / Deutsch（手动锁定或跟随系统）
- **平台能力**：锁屏/远控（MediaSession / MPRemoteCommandCenter）、媒体通知展开歌词行、前台服务、音频焦点与中断处理

## 架构

- **Flutter/Dart**（`lib/`）：UI 与业务编排，Riverpod 状态管理
- **Rust FFI 层**（`rust/`）：flutter_rust_bridge 生成的 API + JNI/C 回调，
  依赖 `../core` 的 audio-core
- **音频输出**：
  - Android：audio-core 经 Oboe/AAudio 直驱设备（Exclusive/Shared 自动协商）
  - iOS：audio-core headless ringbuf → `AVAudioSourceNode` 回调拉取 PCM
- **平台集成**：锁屏/远控（MediaSession / MPRemoteCommandCenter）、
  前台服务、音频焦点、中断与路由变化处理

## 开发

```sh
flutter pub get
flutter run                          # 默认设备
./tools/run.sh                       # 项目封装的运行脚本
flutter_rust_bridge_codegen generate # 修改 rust/src/api 后重新生成桥接代码
```

Rust 代码由 `rust_builder`（cargokit）在 gradle/xcode 构建中自动编译，
无需手动 cargo build。

## 测试

```sh
flutter test                         # 纯 Dart 单元/组件测试（无需真机）
flutter test integration_test        # 集成测试（需真机/模拟器）
cargo test --manifest-path rust/Cargo.toml  # Rust 侧数据通路测试
```

## 目录约定

| 目录 | 职责 |
|---|---|
| `lib/data` | repositories + services（Rust 服务门面、平台通道、NAS 源） |
| `lib/domain` | 领域模型 |
| `lib/ui` | core（主题/路由/共享组件）+ features（library/playback/settings） |
| `lib/l10n` | ARB 本地化资源 + 生成的 Localizations（zh/en/ja/ko/de） |
| `lib/src/rust` | FRB 生成代码，勿手改 |
| `rust/src/api` | FRB 扫描的 API 模块 |
| `rust/src/ffi.rs` | 不被 FRB 扫描的 JNI/C 回调（裸指针参数） |
| `ios/Runner` | `AppDelegate.swift`（启动/会话通知）+ `AudioOutputManager.swift`（AVAudioEngine/锁屏）+ `AppDelegate+Channels.swift`（MethodChannel 处理） |
| `android/app` | `MainActivity`（通道桥）+ `PlaybackService`（前台服务/MediaSession）+ `AudioEngine`（音频焦点/拔耳机）；PCM 由 Rust Oboe 直驱 |
