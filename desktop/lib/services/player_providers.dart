import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nas_service.dart';
import 'network_source_config.dart';
import 'player_notifier.dart';

/// 播放器唯一权威 provider：不可变 [PlayerState] + [PlayerNotifier] 命令面。
///
/// UI 读取状态用 `ref.watch(playerProvider.select((s) => s.xxx))` 精细订阅
/// （对齐 mobile audioPlayerProvider 模式）；命令用
/// `ref.read(playerProvider.notifier).togglePlay()` 等。
///
/// select 按值比较天然覆盖旧 currentIndexProvider 的「同 index 不同曲目」
/// 通知 bug（Track 实例不同即触发 rebuild），不再需要 map 成 Object 的 hack。
final playerProvider =
    NotifierProvider<PlayerNotifier, PlayerState>(PlayerNotifier.new);

/// 实时频谱事件流（16 频段 0~1，引擎 ~25Hz 连续推送）。
/// 连续高频数据属「事件流」而非 UI 状态，StreamProvider 是正确工具
/// （进 State 会让 select 之外的比较开销被 25Hz 放大）。
final spectrumProvider = StreamProvider<List<double>>(
    (ref) => ref.watch(playerProvider.notifier).spectrumStream);

/// 用户可读错误事件（持久化失败等），UI 订阅后弹 SnackBar。
final playerErrorProvider = StreamProvider<String>(
    (ref) => ref.watch(playerProvider.notifier).errorStream);

/// 音频分析完成通知（广播 trackId）：播放页据此刷新 BPM/Key 徽章。
final analysisProvider = StreamProvider<String>(
    (ref) => ref.watch(playerProvider.notifier).analysisStream);

/// 网络音源配置变化（保存凭据 / 切换展示开关时广播），供侧栏刷新状态。
final networkConfigProvider = StreamProvider<Object>(
    (ref) => NetworkSourceConfig.instance.onChange.map((_) => Object()));

/// NAS 连接状态流（disconnected/connecting/connected/error）。
final nasStateProvider = StreamProvider<NasConnectionState>(
    (ref) => NasService.stateStream);
