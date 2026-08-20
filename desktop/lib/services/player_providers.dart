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
/// 当前曲目变化通知。
///
/// 注意：不能直接桥接 `StreamProvider<int?>` 的 indexStream —— Riverpod 默认
/// updateShouldNotify（`previous != next`）按值比较，切歌时若两次 index 相同
/// （随机模式点歌恒为 0、playNext 插入后 index 不变、不同视图同位索引），
/// 通知会被跳过，导致右侧封面 / 列表高亮不刷新。
/// 因此与下方「纯通知」流一致：map 成每次新分配的 Object 强制每回都通知；
/// UI 拿到信号后读 `player.currentTrack`（本 provider 的值无业务意义）。
final currentIndexProvider = StreamProvider<Object>(
    (ref) => ref.watch(playerControllerProvider).indexStream.map((_) => Object()));
final lyricsProvider = StreamProvider<List<LyricLine>>(
    (ref) => ref.watch(playerControllerProvider).lyricsStream);
/// 这些流只承担「通知刷新」职责，emit 值本身无意义（广播 null）。
/// 若用 `StreamProvider<void>`，每次 emit 的 AsyncData(null) 相互相等，
/// Riverpod 默认 updateShouldNotify（`previous != next`）判定「无变化」而跳过通知，
/// 导致扫描完成 / 收藏切换后 UI 不刷新（需切 tab/重启才出现）。
/// 因此 map 成每次新分配的 Object 实例，强制每次 emit 都触发 rebuild。
final favoritesProvider = StreamProvider<Object>(
    (ref) => ref.watch(playerControllerProvider).favoritesStream.map((_) => Object()));
final playlistsProvider = StreamProvider<Object>(
    (ref) => ref.watch(playerControllerProvider).playlistsStream.map((_) => Object()));
final modeProvider = StreamProvider<Object>(
    (ref) => ref.watch(playerControllerProvider).modeStream.map((_) => Object()));
final libraryProvider = StreamProvider<Object>(
    (ref) => ref.watch(playerControllerProvider).libraryStream.map((_) => Object()));

/// 网络音源配置变化（保存凭据 / 切换展示开关时广播），供侧栏刷新状态。
/// 与上方 favorites/library 等「纯通知」流一致：map 成每次新分配的 Object
/// 强制每回都通知，避免 Riverpod 因 AsyncData(null) 相等而跳过 rebuild
/// （L38-41 注释描述的同一类 bug，本 provider 此前漏修）。
final networkConfigProvider = StreamProvider<Object>(
    (ref) => NetworkSourceConfig.instance.onChange.map((_) => Object()));

/// NAS 连接状态流（disconnected/connecting/connected/error）。
final nasStateProvider = StreamProvider<NasConnectionState>(
    (ref) => NasService.stateStream);
