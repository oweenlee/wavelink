# WaveLink PC 端（Flutter）MVP 实施计划

> 目标：用 Flutter 重写 / 完善 `desktop/`，并让桌面端继承 Rust `core` 的
> hi-res / DSP / bit-perfect 能力（而不是当前脚手架里的纯 Dart `audioplayers`）。
> 本文件是 **计划**，落地前需确认「核心决策」两节。

---

## 0. 实施状态（2026-08-18 更新）

**已确认决策**：A1 桥接 Rust core ✅ · B1 独立 `desktop/` 工程 ✅

**已完成（Phase 1 主体）**
- [x] FFI 构建 Spike：验证 `core` 桌面 cpal 后端可编译、dylib 可加载（初始选手动 C-ABI，
      23 个 `wavelink_*` 符号与 Dart 侧逐一匹配，已验证可行）。
- [x] 真实播放：play/pause/resume/stop/seek/next/prev + position/duration/stopped
      事件（替换 audioplayers）。
- [x] 曲库扫描：本地目录递归扫描，去掉强制 mock，空库引导（file_selector 添加文件夹）。
- [x] 播放状态机：保留队列/随机/循环/收藏/播放列表/音量 + shared_preferences 持久化。
- [x] PC 原生 UI：侧栏 + 主区 + 常驻「正在播放」面板；快捷键 Space/←/→/⌘F。
- [x] 状态管理迁移 **Riverpod 3.4.2**：单例 `playerControllerProvider` + 8 个状态
      `StreamProvider`，UI 全面改用 `ref.watch`（移除手写 StreamBuilder 订阅）。
- [x] 图标统一 **lucide_icons_flutter 3.1.15**：替换全部 Material `Icons.*`。
- [x] 与 mobile 第三方库对齐：`shared_preferences`(^2.3.0) / `riverpod` / `lucide` /
      `path_provider` / `package_info_plus` 已统一；移除 `cupertino_icons`。
- [x] `flutter analyze` 零 error。

**绑定层统一（已完成）**
- [x] 桌面 Rust 绑定迁移到 **flutter_rust_bridge 2.13.0-beta.5**（与 mobile 同版本）：
      `desktop/rust` 经 `#[frb]` 标注 + codegen 生成 `frb_generated.rs` 与 Dart 绑定，
      dylib 经 `RustLib.init(externalLibrary:)` 加载。两端绑定层**完全统一**。
- [x] 移除 `ffi` 依赖与手写 `engine.dart` FFI 定义；`cargo build -p wavelink_desktop`
      + `flutter analyze` 双端零 error。

**待办（Phase 2+）**
- [ ] Windows WASAPI / Linux 真机验证与 `.dll`/`.so` 加载路径
- [ ] 打包：把 dylib 拷入 app bundle（Frameworks），让 `flutter build macos` 可用
- [ ] DSP 控制 UI（EQ/AutoEQ/房间校正）、bit-perfect/独占开关、输出设备选择 UI
- [ ] 频谱可视化、gapless 无缝播放
- [ ] 网络源（WebDAV/SMB/Subsonic）

> 注：根 README、`desktop/README.md`（原 §5.7「清理」项）已随本文档一并更新；
> 旧 Tauri/Svelte 描述已移除。

---

## 1. 背景与现状

| 目录 | 真实状态 |
|------|----------|
| `core/` | 纯 Rust 音频引擎（解码 + DSP 管线 + 引擎 + 多后端输出）。零 C 依赖，跨 macOS/Windows/Linux/Android/iOS。**已自带桌面输出后端**：`cpal-backend`（默认，跨平台）、`audiounit-backend`（macOS）、`wasapi-backend`（Windows）。这是产品核心价值（hi-res / bit-perfect / AutoEQ / 房间校正），必须保留。 |
| `mobile/` | Flutter + Rust FFI（`flutter_rust_bridge`）。`mobile/rust`（`rust_lib_wavelink_mobile`）包 `audio-core`，经 FRB 暴露 API；移动端输出走 Oboe（Android）/ `AVAudioSourceNode`（iOS）。 |
| `desktop/` | **当前是一个全新的 Flutter 脚手架**（`local_music_player`），用 `audioplayers`（纯 Dart 播放器）做播放，`window_manager` + `tray_manager` 做窗口 / 托盘。根 README 仍写「Tauri + Svelte 5」，已过时。 |
| `desktop/lib` | 已有较好骨架：`main.dart`（窗口/托盘集成）、`PlayerController`（队列/随机/循环/收藏/播放列表/音量状态机 + 广播流）、`library.dart`（本地目录扫描 + mock 回退）、`models/`、`services/`、`screens/home.dart`。 |

**核心问题**：当前 desktop 用的 `audioplayers` 是纯 Dart 播放器，**没有 hi-res / DSP / bit-perfect**，直接违背产品定位。而 Rust `core` 本就支持桌面输出后端，可以直接驱动桌面声卡——不需要 audioplayers。

---

## 2. 核心决策（落地前需确认）

### 决策 A — 音频引擎来源（最关键）
- **方案 A1（推荐）：Flutter 通过 FFI 桥接 Rust `core`。**
  桌面端继承全部 hi-res / DSP / bit-perfect 能力，与移动端共用同一份 Rust 音频核心。`core` 的 `EngineHandle` 已提供 `play/pause/resume/stop/seek/next/prev`、队列、音量、EQ/AutoEQ、设备枚举、position/duration/levels 事件。
- 方案 A2：纯 Dart `audioplayers` / `just_audio` 先跑通 MVP，Rust 桥接后置。
  简单，但**失去 hi-res/bit-perfect**，等于重新做一个普通播放器，与产品定位冲突。仅适合「先验证 UI」的临时分支。

> 依据：用户长期产品意图是「纯本地 hi-res 播放器，真 bit-perfect 输出」；`core` 的 `bit_perfect` / `exclusive_mode` 已就绪。纯 Dart 做不到 bit-perfect，必须原生音频层。

### 决策 B — 工程结构
- **方案 B1（推荐）：在现有独立 `desktop/` Flutter 工程上构建。** 你已新建独立 `desktop/`，且「完善 desktop」的诉求直接指向它。
- 方案 B2：并入 `mobile/` 单一代码库（早前讨论过的方案：在 `mobile/` 内加 `macos/`、`windows/` 嵌入层）。共享 lib 更彻底，但与当前已存在的独立 `desktop/` 工程冲突，重构成本高。

> 注：早前的方案文档曾倾向 B2，但现状已演化为独立 `desktop/` 脚手架，故默认按 B1 推进，除非你明确要求回归 B2。

---

## 3. 目标架构（MVP）

```
Flutter UI  (desktop/lib)
   │   FFI（dart:ffi 手动 C-ABI）绑定（engine.dart 封装）
   ▼
desktop/rust  (新建 crate，cdylib + staticlib)
   │   path 依赖 → core/ (audio-core)
   │   启用 cpal-backend（mac/win/linux 通用）
   │   后续可选 audiounit-backend / wasapi-backend（独占/bit-perfect 体验）
   ▼
桌面声卡 (cpal / AudioUnit / WASAPI)
```

- 新建 `desktop/rust/` crate，用 **手动 C-ABI（dart:ffi）** 暴露**桌面版** API（不走 FRB，见 §0 实际落地）：
  - 启动引擎（`engine_start(config)`）
  - 文件播放 / 队列（`play(path)` / `play_queue(paths, at)`）
  - 控制（`pause/resume/stop/seek/next/prev/set_volume`）
  - 查询（`position_secs/duration_secs/is_playing/underrun_count`）
  - 设备枚举（`enumerate_devices`，后续接设备选择 UI）
  - 事件流（`EngineEvent`：Position / Duration / State / TrackEnded）
- Dart 侧新增 `lib/services/engine.dart` 封装 **FFI（dart:ffi 手动 C-ABI）** 绑定；`PlayerController` 改为调用它，**保留现有状态机与持久化**。
- 移除 `audioplayers` 依赖；`pubspec.yaml` 加入 `ffi` / `file_selector`。

> **实际落地（Spike 结果）**：桌面版 **未采用 FRB/cargokit**，改用手动 C-ABI
> （`dart:ffi` + `DynamicLibrary.open`）。原因：本环境 FRB+cargokit 桌面
> 工具链脆弱、耗时长；手动 C-ABI 同样保留「Rust core 驱动桌面音频 + 事件轮询」
> 架构，并镜像 mobile 的命名与事件模型，可靠性高、用户构建简单。若日后要与
> mobile 完全统一生成代码，可再迁移 FRB（非阻塞）。

> 复用提示：`mobile/rust/src/api` 是 FRB API 范本，桌面版**仅镜像其函数命名与
> 轮询事件模型**（不用 FRB 生成），降低风险。因桌面未引入 FRB，无 FRB 版本对齐要求。

### 3.1 参考 mobile / 但保持 PC 特有交互（用户补充原则）

**可以复用 mobile 的部分（作为事实来源，不是 UI 模板）：**
- **Rust FFI 桥接架构**：`mobile/rust` 用 `flutter_rust_bridge` 包 `audio-core` 的模式，桌面版 `desktop/rust` 直接镜像（含 `crate-type = ["cdylib","staticlib"]`、C-ABI 暴露、`dart:ffi` 加载、事件轮询）。桌面版**不使用 FRB 代码生成**（见 §0 实际落地）。
- **FRB API 形状**：`mobile/rust/src/api/engine.rs` 是现成范本——`engine_init/ex`、`engine_play/pause/resume/stop/seek/next/prev`、`engine_set_*` 系列（PEQ/AutoEQ/房间校正 IR/ReplayGain/音量/速度/跨馈/展宽/限幅/抖动）、`engine_position/duration/is_playing/levels/underrun_count`、`engine_poll_events` / `engine_take_event` **轮询式事件模型**（Dart 定时 poll，非 FRB Stream）。桌面版沿用同一套命名与轮询机制，风险最低。
- **功能定义**：EQ / AutoEQ（oratory1990 档案）/ 房间校正 / 歌词 / 曲库模型 / 播放状态机这些「功能语义」从 mobile 对齐，保证两端能力一致。
- **`core` 集成细节**：bit-perfect / 独占模式 / DSD / 设备枚举的语义以 `core` 为准，两端只透传不改写（与现有约定一致）。

**不能等比例放大 mobile（PC 要自己设计交互）：**
- mobile 是 **竖屏 + 底部 Tab + 手势 + 底部 mini-player** 的范式；PC 是 **窗口化、多面板、键鼠驱动**。以下为 PC 特有交互，须从零设计，而非把手机界面放大：

| 维度 | mobile（仅参考，不照搬） | PC（MVP 要做的原生交互） |
|------|--------------------------|--------------------------|
| 布局 | 底部 Tab + 单栏 + 底部播放条 | 左侧栏导航（曲库/音源/设置）+ 多面板主区（列表/网格）+ 常驻「正在播放」面板；可缩放、非手机屏 |
| 导航 | 手势 / Tab 切换 | 侧栏 + 列导航 + 可折叠面板 |
| 输入 | 触摸 / 长按弹 sheet | **键盘快捷键**（Space 播放暂停、←/→ seek、媒体键经系统）、**右键上下文菜单**（加入队列/播放列表/打开文件位置/属性）、**拖拽**（拖文件/文件夹入窗口加曲库、拖拽重排队列） |
| 窗口 | 全屏 App | **最小化到托盘**（脚手架已做）、**系统媒体控制**（macOS NowPlaying / Windows SMTC / Linux MPRIS）——mobile 的 MediaSession 锁屏对应物 |
| 信息密度 | 极简、一屏一事 | 更高密度：频谱可视化、歌词与封面并排、常驻队列面板、多列浏览 |
| 文件系统 | 云源（SMB/WebDAV/Subsonic/Apple Music） | **本地文件夹**：「打开文件夹」「添加曲库目录」、拖文件夹——PC 原生；网络源 Phase 2+ |
| 音频路由 | 移动端独占协商 | 桌面 **输出设备选择**（枚举设备）+ 缓冲/独占/bit-perfect 开关（PC/Mac 特有） |

> MVP 落地口径：`home.dart` 不作为「放大版手机页」保留，而是**重构成 PC 原生布局**（侧栏 + 主区 + 播放面板）；`PlayerController` 状态机与 `library` 扫描可复用，但视图层与交互按上表重写。

---

## 4. MVP 范围（Phase 1）

**做：**
1. **FFI 构建链路 Spike（最高优先级）**：最小 `desktop/rust` cdylib + FRB 绑定，mac 上 `cargo build` 产出 `.dylib` 并被 Flutter `DynamicLibrary.open` 加载、能真出声。确认 cargokit 是否支持桌面；不支持则走手动 dylib + 拷贝到 build 产物。
2. **真实播放**：`play/pause/resume/stop/seek/next/prev`，位置/时长/结束来自 Rust 引擎事件流（替换 audioplayers 的回调）。
3. **曲库扫描**：保留 `library.dart` 本地目录递归扫描；去掉「强制 mock 回退」，改为无曲目时 UI 提示空库。
4. **播放状态机**：保留 `PlayerController`（队列/随机/循环/收藏/播放列表/音量），仅替换音频后端。
5. **窗口/托盘**：保留 `main.dart` 现有 `window_manager` + `tray_manager` 集成（关闭最小化到托盘）。
6. **基础 UI（PC 原生，非放大手机）**：将 `home.dart` 重写为 **PC 布局**——左侧栏（曲库 / 设置）+ 主区（曲库列表）+ 常驻「正在播放」面板（封面 / 进度 / 控制）。实现 PC 特有交互的最小子集：键盘快捷键（Space 播放暂停、←/→ seek）、右键菜单（加入队列 / 播放列表）、拖文件入窗口加曲库。复用 `PlayerController` 状态机与 `library` 扫描，仅替换视图层与交互。
7. **一键构建**：明确 `cargo build`（rust）+ `flutter run` 流程。

**不做（Phase 2+）：**
- DSP 控制 UI（EQ / AutoEQ / 房间校正 / 跨馈 / 展宽）——引擎已支持，仅 UI 后置。
- bit-perfect / 独占模式开关 UI（引擎已支持，先留 API）。
- 网络源（WebDAV / SMB / Subsonic）——移动端已有，桌面 MVP 只做本地文件。
- 频谱可视化（引擎已 emit `Levels`，UI 后置）。
- 跨平台 CI、签名、打包分发（dmg / msi）。

---

## 5. 实施步骤

1. **Spike：FFI 构建链路**（最大风险）
   - 在 `desktop/rust` 建最小 `cdylib`，暴露 `engine_start()` / `play(path)`。
   - （桌面未采用 FRB 代码生成；用手动 C-ABI + `DynamicLibrary.open`，见 §0 实际落地说明。）
   - 验证 mac 上 dylib 被加载、能出声。
   - 确认 cargokit 桌面支持；不支持则确定手动 dylib + `DynamicLibrary.open` 的加载路径与拷贝步骤。
2. **桌面 Rust crate**：扩展 API —— 队列、seek、音量、设备枚举、事件流（position/duration/state/ended）。启用 `cpal-backend`。
3. **Dart 引擎服务** `engine.dart`：封装 FRB 绑定为简洁 API + 把 `EngineEvent` 转成 `PlayerController` 用的广播流。
4. **接入 `PlayerController`**：用 engine 服务替换 audioplayers；保留状态机与 `shared_preferences` 持久化；移除 `isSimulated`/定时器模拟分支。
5. **UI 重写为 PC 原生布局**：侧栏 + 主区 + 常驻播放面板；接入真实播放与 `library` 扫描（去掉强制 mock，空库提示）；实现 PC 交互最小子集（快捷键 / 右键菜单 / 拖文件加曲库）。参考 mobile 的功能语义，但不照搬其竖屏/Tab/手势范式。
6. **Windows 验证**：重复 Spike 在 Windows 出声（WASAPI 后端），确认 `cdylib`(.dll) 加载路径。
7. **清理**：更新根 README 的 desktop 段（改为「Flutter + Rust FFI」）；删除 `audioplayers` 依赖；移除过时 Tauri 描述。

---

## 6. 风险

- **FFI 构建集成**：cargokit 是否支持桌面（mac/win）是最大不确定项；若不支持，需手动管理 dylib 构建与拷贝。→ 用 Step 1 Spike 先行验证，不过早全面铺开。
- **`core` 桌面后端实测稳定性**：移动端跑的是 Oboe / AVAudio，cpal / AudioUnit / WASAPI 桌面路径尚未在移动端验证过，需在真机（mac/win）实测出声、seek、切歌、underrun。
- **FRB 版本对齐**：桌面 crate 须与 mobile 用同一 FRB 版本（`=2.13.0-beta.5`），避免生成代码不兼容。

---

## 7. 验证

- `flutter test`：Dart 状态机单测（队列/随机/循环/收藏，不依赖真实音频）。
- 手动：本地目录放几首 flac / mp3 → mac 出声、进度 / seek / 切歌 / 音量正常、收藏持久化。
- Windows：WASAPI 后端出声验证。
- 抽查 `core` 事件流正确驱动 UI（Position / Duration / TrackEnded）。
