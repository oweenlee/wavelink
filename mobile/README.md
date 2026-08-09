# WaveLink Mobile

WaveLink 移动端播放器（Android + iOS），与桌面端共享 [audio-core](../core) 音频引擎。

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
| `lib/src/rust` | FRB 生成代码，勿手改 |
| `rust/src/api` | FRB 扫描的 API 模块 |
| `rust/src/ffi.rs` | 不被 FRB 扫描的 JNI/C 回调（裸指针参数） |
| `ios/Runner` | `AppDelegate.swift`（启动/会话通知）+ `AudioOutputManager.swift`（AVAudioEngine/锁屏）+ `AppDelegate+Channels.swift`（MethodChannel 处理） |
| `android/app` | `MainActivity`（通道桥）+ `PlaybackService`（前台服务/MediaSession）+ `AudioEngine`（音频焦点/拔耳机）；PCM 由 Rust Oboe 直驱 |
