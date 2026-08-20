# WaveLink 桌面端（Flutter + Rust FFI）

本地音乐播放器，桌面端。UI 用 Flutter，音频引擎桥接项目共享的纯 Rust
`core` 音频核心，继承 hi-res / DSP / bit-perfect 能力——**不走纯 Dart 播放器**。

## 架构

```
Flutter UI  (lib/)
   │  flutter_rust_bridge 生成的 Dart 绑定（RustLib.init 加载 dylib）
   ▼
libwavelink_desktop.{dylib,dll,so}   ← desktop/rust (crate wavelink_desktop)
   │  path 依赖 → core/ (audio-core)
   ▼
桌面声卡：macOS AudioUnit · Windows WASAPI · Linux cpal/ALSA
```

- Rust 桥接层：`desktop/rust/`（cdylib + 由 `flutter_rust_bridge` 生成
  `frb_generated.rs`），经 `#[frb]` 标注暴露 `wavelink*` 函数（init / play /
  pause / seek / set_volume / 事件轮询等）。事件用 JSON **轮询模型**
  （Dart 侧 40ms 定时 poll），命名与事件模型镜像 `mobile/rust`。
- 解码：`core` 内的 symphonia；输出：`core` 的 cpal 后端（按平台分发到
  AudioUnit / WASAPI / ALSA）。**已用 `flutter_rust_bridge` 2.13.0-beta.5
  与 mobile 统一绑定层**，dylib 经 `RustLib.init(externalLibrary:)` 加载。

## 构建与运行

前置：Rust 工具链（cargo）+ Flutter 3.x，且已 `flutter config --enable-macos-desktop`。

```bash
# 1) 编译 Rust 引擎（只需一次，改了 Rust 才需重编）
cd /Users/qin/Desktop/wavelink
cargo build -p wavelink_desktop
#   产物：target/debug/libwavelink_desktop.dylib (mac) / .dll (win) / .so (linux)

# 2) 运行（必须从本目录 desktop/ 启动，FFI 才能找到 ../target/... 的 dylib）
cd /Users/qin/Desktop/wavelink/desktop
flutter pub get
flutter run -d macos
```

首屏默认从 `/Users/qin/Public/music` 加载（不存在则空库）。点左侧
**「添加音乐文件夹」**选本地目录即可扫描播放。

## 与 mobile 第三方库对齐（合并友好）

为降低将来两端合并的阻力、统一排查口径，桌面端已主动对齐 mobile 的通用库选择：

| 库 | 版本 | 作用 | 状态 |
|---|---|---|---|
| `shared_preferences` | ^2.3.0 | 本地 KV 持久化（音量/循环/收藏/播放列表） | ✅ 已对齐 |
| `flutter_riverpod` | 3.4.2 | 状态管理（已接入：单例 Provider + 8 个状态 `StreamProvider`，UI 用 `ref.watch` 消费） | ✅ 已对齐 |
| `lucide_icons_flutter` | ^3.1.15 | 图标语言（已替换全部 Material `Icons.*`，与 mobile 视觉一致） | ✅ 已对齐 |
| `path_provider` | ^2.1.0 | 应用数据/缓存目录 | ✅ 已引入 |
| `package_info_plus` | ^8.0.0 | app 版本/包名（关于页/日志用） | ✅ 已引入 |
| `flutter_rust_bridge` | 2.13.0-beta.5 | Rust↔Dart 绑定生成（**与 mobile 同版本，绑定层已统一**） | ✅ 已统一 |

> 两端 Rust 绑定层已实现完全统一：均经 `flutter_rust_bridge` 2.13.0-beta.5
> 生成，共享 `core` 音频引擎。差异仅剩桌面特有平台库（tray / window_manager /
> file_selector）与 mobile 的云源/平台库（connectivity 等）。

## 网络音源（WebDAV / NAS(SMB) / Subsonic）

桌面端已实现网络音频源，架构与 `mobile` 对齐，复用其扫描 / 下载 / 播放派发逻辑：

- **`TrackSource` 枚举**（`local` / `webdav` / `nas` / `subsonic`）区分本地播放与网络流式播放。网络曲携带 `remotePath` / `streamUrl` / `coverUrl` / `durationHint` 字段，本地曲保留 `filePath`。
- **配置中心 `NetworkSourceConfig`**（单例，SharedPreferences 持久化，配置变化经 `onChange` 广播给 `networkConfigProvider`）。合并了 mobile 拆分过细的 `PreferencesService`，统一持有三类来源的凭据与曲库展示开关。
- **三类服务**（均在 `lib/services/`，端口自 mobile）：
  - `WebdavService` — 目录扫描 + 并行 Range 分块下载（`engineWebdavFileSize` / `engineWebdavDownloadRange`），边下边播为主、整曲缓存兜底。
  - `NasService` — 经 Rust `frb_smb` 做 SMB2/3 连接 / 共享枚举 / 目录扫描 / keepalive；连接状态经 `stateStream` 广播给 `nasStateProvider`（侧栏实时显示已连接/未连接）。
  - `SubsonicService` — `ping` + `scanLibrary`（分页 `getAlbumList2`→`getAlbum`）拉取 Navidrome / Jellyfin 曲库；`streamUrl` 走 `/rest/stream`，下载到缓存后本地播放。
- **播放派发**（`PlayerController`）：本地 → `engine.play(path)`；WebDAV / NAS → Rust 流式（`enginePlayWebdavStream` / `enginePlaySmbStream`，失败回退整曲缓存下载）；Subsonic → 下载 `streamUrl` 到缓存后本地播放。`playIndex` 先用 `durationHint` 预填进度条，避免网络曲时长未知导致进度条不动。
- **侧栏「网络音源」区** + `NetworkConfigDialog`（`lib/screens/network_dialogs.dart`）：按来源填写凭据，`测试连接` → `保存` → `扫描并导入`（去重并入曲库）。导入入口 `importWebdav/importNas/importSubsonic`。

> 侧栏网络曲显示来源徽标（`DAV` / `NAS` / `SUB`），本地曲显示文件扩展名或「模拟」（纯 Dart 回退）；CUE 虚拟分轨显示 `CUE` 徽标。

## 本地曲库扫描（标签元数据 + CUE 分轨）

`addFolder` 后的扫描（`lib/services/library.dart`）分两阶段，引擎未加载/读取失败时静默降级文件名「艺人 - 标题」规则，扫描永远可用：

- **阶段 1 — CUE 展开**：解析目录内全部 `.cue`（经 Rust `parse_cue_bytes`，UTF-8 失败回退 GBK——中文/日文抓轨常见编码），整轨镜像拆成逐首虚拟曲目（`Track.cuePath` / `cueTrackIndex` / `cueTrackCount`），被引用的镜像音频文件不重复入库；镜像全部缺失时不排除，整轨仍以普通曲目保留。
- **阶段 2 — 标签增强**：8 路并发经 Rust `read_metadata` 读真实标签（标题/艺人/专辑/音轨号/时长/内嵌歌词），封面字节顺手写入 `.covers` 缓存（省去后台二次解析）；外部同名 `.lrc` 仍在扫描期记录。
- **排序**：艺人 → 专辑 → 音轨号 → 标题（无标签曲目行为与旧版一致）。时长曲目行可见，供进度提示。
- **CUE 播放**：`playQueueAt([cuePath], 轨号)` 起播后逐条 `removeQueueEntry` 清空引擎侧的整碟剩余分轨——队列控制权始终归 Dart（随机/循环/播放列表语义生效）；core 的 position/duration/seek 均为虚拟轨相对值，UI 零适配。
- **新 FFI 模块**：`desktop/rust/src/api/metadata.rs`（`read_metadata`）、`cue.rs`（`parse_cue_bytes`，与 core 的 UTF-8-only `parse_cue` 不同，桥接层先解码再走 `parse_cue_str`）；`engine.rs` 增 `wavelink_remove_from_queue`。改 Rust 后需重跑 `flutter_rust_bridge_codegen generate`。

## 快捷键

| 按键 | 功能 |
|------|------|
| Space | 播放 / 暂停 |
| ← / → | 快退 / 快进 5 秒 |
| ⌘F / Ctrl+F | 聚焦搜索 |

## 当前状态（MVP）

- ✅ Rust `core` 桌面后端编译 + FFI 桥接 + dylib 加载验证（23/23 符号匹配）
- ✅ 真实播放（逐首）：play/pause/resume/stop/seek/next/prev + 进度/时长/结束事件
- ✅ 曲库本地目录扫描（无强制 mock，空库引导）
- ✅ 播放状态机：队列 / 随机 / 循环 / 收藏 / 播放列表 / 音量（shared_preferences 持久化）
- ✅ PC 原生布局：侧栏 + 主区 + 常驻「正在播放」面板；`flutter analyze` 零 error
- ✅ 状态管理迁移 Riverpod（单例 + 8 个状态 `StreamProvider`，UI 全面 `ref.watch`）
- ✅ 图标统一 Lucide（替换全部 Material 图标，与 mobile 视觉一致）
- ✅ 通用库对齐 mobile：`shared_preferences`/`riverpod`/`lucide`/`path_provider`/`package_info_plus`
- ✅ **Rust 绑定层迁移到 FRB 2.13.0-beta.5**（与 mobile 同版本），dylib 经 `RustLib.init(externalLibrary:)` 加载；`cargo build` + `flutter analyze` 双端零错误
- ✅ macOS 真机验证通过（出声 / dylib 加载 / 事件轮询 / UI 渲染全链路）
- ✅ 代码 review 修复（2026-08-18）：事件泵按周期抽干（上限 64/次）；seek 毫秒精度；音量/进度拖动 `onChangeEnd` 提交（拖动不再每帧写盘/调引擎）；曲库文件夹持久化（重启恢复）；`playNext` shuffle 下基准队列插入位置修正；Rust 引擎 `Mutex<Option>` 化（deinit 后可重新 init）；非阻塞启动；主题色单源 `lib/core/theme.dart`
- ✅ 单元测试：`flutter test` 71 用例全绿（PlayerController 状态机 / LRC 解析 / 目录扫描 / 空库 UI 冒烟 / 网络音源侧栏 / 标签元数据 + CUE 真 dylib 全链路）；`analysis_options.yaml` 开启 `strict-casts / strict-inference / strict-raw-types`
- ✅ **网络音源（WebDAV / NAS(SMB) / Subsonic）**：`TrackSource` 枚举 + `NetworkSourceConfig` 配置中心 + `WebdavService`/`NasService`/`SubsonicService` 扫描下载 + 播放派发（`PlayerController` 流式 vs 缓存兜底）+ 侧栏「网络音源」区与 `NetworkConfigDialog`；`cargo check` / `flutter analyze` 双端零错误
- ✅ **标签元数据增强（2026-08-20）**：扫描期经 Rust `read_metadata` 读真实标签（标题/艺人/专辑/音轨号/时长/内嵌歌词），封面字节扫描期顺手落盘缓存；失败降级文件名「艺人 - 标题」规则；曲库排序升级为 艺人→专辑→音轨号→标题；曲目行显示真实时长；内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 ©lyr）作外部 .lrc 兜底
- ✅ **CUE 分轨（2026-08-20）**：扫描期解析 `.cue`（UTF-8/GBK 双编码，经 `parse_cue_bytes`），整轨镜像拆逐首虚拟曲目入库（镜像文件不重复入库）；播放经 `playQueueAt + removeQueueEntry` 从指定分轨起播，引擎 position/duration/seek 均为虚拟轨相对值，队列控制权归 Dart；曲目行 CUE 徽标
- ✅ **频谱可视化（2026-08-20）**：引擎 `spectrum` 事件（16 频段）经 `PlayerController.spectrumStream` 广播，「正在播放」面板 `SpectrumVisualizer` 渲染（快攻慢放平滑 + 暂停衰减 + RepaintBoundary 隔离，颜色随封面强调色）

### 未做（Phase 2+）
- Windows/WASAPI、Linux 真机验证与打包（dmg/msi，把 dylib 拷入 app bundle）
- DSP 控制 UI 补全（逐段 PEQ 自定义界面，预设/AutoEQ/房间校正已有）、bit-perfect/独占开关 UI 打磨、输出设备选择 UI 打磨
- gapless 无缝播放（当前逐文件，切歌有极短间隔；引擎侧整队列 API 已预留未接线；CUE 分轨切换亦为逐次起播）
- 桌面原生体验：全局媒体键（macOS 媒体键 / Windows SMTC / Linux MPRIS）、定时关闭、开机自启
- 结构性重构（拆分 PlayerController 职责 / home.dart 按组件拆文件）——有意推迟，收益低于回归风险

### mobile 侧已知状态（仅记录未改，桌面端不受影响）

- ~~GBK cue 解析失败~~ **已修**：mobile 桥接层已改为 `parse_cue_bytes`（先试 UTF-8 剥 BOM，失败回退 GBK，再走 `parse_cue_str`），与桌面同款；另已将 `engine_play_queue_at` 暴露到 FFI，将来接线随时可用。
- CUE 仍未接入 mobile 的 UI/曲库/播放链路（`parseCueBytes` 有包装但无消费者）——有意识保留：移动端导入渠道（MediaStore/Subsonic/NAS/WebDAV）几乎不会产生 cue 文件，整轨镜像用户集中在桌面端。将来要接线时，播放模型照抄桌面（`enginePlayQueueAt` 起播 + 清空引擎残余队列）。
