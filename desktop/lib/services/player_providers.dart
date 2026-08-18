import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lyrics.dart';
import 'nas_service.dart';
import 'network_source_config.dart';
import 'player_controller.dart';

/// 播放控制器单例。由 Riverpod 管理生命周期（dispose 时释放 Rust 引擎）。
/// 权威实例在 main() 经 ProviderContainer 读取并 init，UI 通过 ref.watch 取用，
/// 共享同一实例（与 mobile 统一使用 Riverpod 做状态管理）。
final playerControllerProvider = Provider<PlayerController>((ref) {
  final c = PlayerController();
  ref.onDispose(c.dispose);
  return c;
});

/// 把 PlayerController 的广播流桥接为 Riverpod 可 watch 的状态。
/// UI 用 ref.watch(xxxProvider) 替代 StreamBuilder，统一状态消费方式。
final positionProvider = StreamProvider<Duration>(
    (ref) => ref.watch(playerControllerProvider).positionStream);
final durationProvider = StreamProvider<Duration>(
    (ref) => ref.watch(playerControllerProvider).durationStream);
final playingProvider = StreamProvider<bool>(
    (ref) => ref.watch(playerControllerProvider).playingStream);
final currentIndexProvider = StreamProvider<int?>(
    (ref) => ref.watch(playerControllerProvider).indexStream);
final lyricsProvider = StreamProvider<List<LyricLine>>(
    (ref) => ref.watch(playerControllerProvider).lyricsStream);
final favoritesProvider = StreamProvider<void>(
    (ref) => ref.watch(playerControllerProvider).favoritesStream);
final playlistsProvider = StreamProvider<void>(
    (ref) => ref.watch(playerControllerProvider).playlistsStream);
final modeProvider = StreamProvider<void>(
    (ref) => ref.watch(playerControllerProvider).modeStream);
final libraryProvider = StreamProvider<void>(
    (ref) => ref.watch(playerControllerProvider).libraryStream);

/// 网络音源配置变化（保存凭据 / 切换展示开关时广播），供侧栏刷新状态。
final networkConfigProvider = StreamProvider<void>(
    (ref) => NetworkSourceConfig.instance.onChange);

/// NAS 连接状态流（disconnected/connecting/connected/error）。
final nasStateProvider = StreamProvider<NasConnectionState>(
    (ref) => NasService.stateStream);
