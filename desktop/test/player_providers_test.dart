import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/player_controller.dart';
import 'package:local_music_player/services/player_providers.dart';

/// currentIndexProvider 回归测试：同 index、不同曲目的切歌必须触发通知。
///
/// 曾出现 bug：provider 直接桥接 `StreamProvider<int?>` 的 indexStream，
/// 当两次 emit 的 index 相等（随机模式点歌恒为 0、playNext 插入后 index
/// 不变、不同视图同位索引），Riverpod 默认 updateShouldNotify 判定
/// 「无变化」而跳过通知，右侧封面 / 列表高亮随之不刷新。
/// 现 provider 为纯通知流（map 成新 Object），以下场景必须各通知一次。
///
/// 注意：所有断言前需 `await pumpEventQueue()` —— StreamController 默认
/// 异步派发事件（微任务），不等待会拿到未送达的旧计数。
List<Track> mkTracks(int n) => List.generate(
    n,
    (i) => Track(
        id: 't$i', title: 'Track $i', artist: 'A$i', filePath: '/tmp/t$i.flac'));

void main() {
  late ProviderContainer container;
  late PlayerController player;
  late int notified;

  setUp(() {
    container = ProviderContainer();
    player = container.read(playerControllerProvider);
    notified = 0;
    container.listen(
      currentIndexProvider,
      (_, _) => notified++,
    );
    addTearDown(container.dispose);
  });

  test('notifies on first track selection', () async {
    player.playFrom(mkTracks(3), 1);
    await pumpEventQueue();
    expect(player.currentTrack?.id, 't1');
    expect(notified, 1);
  });

  test('notifies when switching to a different track at the same index', () async {
    final ts = mkTracks(3);
    player.playFrom(ts, 1);
    await pumpEventQueue();
    // 同一队列位置 1，但队列内容变化（不同曲目顶上）
    player.playFrom([ts[2], ts[0], ts[1]], 1);
    await pumpEventQueue();
    expect(player.currentIndex, 1);
    expect(player.currentTrack?.id, 't0');
    // 旧实现此处 index 1 == 1 跳过通知，UI 封面/高亮会残留旧曲目
    expect(notified, 2);
  });

  test('shuffle mode: clicking another track still notifies (index stays 0)',
      () async {
    final ts = mkTracks(5);
    await player.toggleShuffle();
    player.playFrom(ts, 2); // 随机队列：t2 置首，index 0
    await pumpEventQueue();
    expect(player.currentTrack?.id, 't2');
    player.playFrom(ts, 4); // 再点 t4：重新洗牌，t4 置首，index 仍 0
    await pumpEventQueue();
    expect(player.currentIndex, 0);
    expect(player.currentTrack?.id, 't4');
    expect(notified, 2);
  });

  test('playNext while playing notifies even though index is unchanged',
      () async {
    final ts = mkTracks(3);
    player.playFrom(ts, 0);
    await pumpEventQueue();
    player.playNext(ts[2]);
    await pumpEventQueue();
    expect(player.currentIndex, 0);
    expect(player.currentTrack?.id, 't0');
    expect(notified, 2);
  });

  test('next() to a new track notifies', () async {
    final ts = mkTracks(3);
    player.playFrom(ts, 0);
    await pumpEventQueue();
    await player.next();
    await pumpEventQueue();
    expect(player.currentIndex, 1);
    expect(player.currentTrack?.id, 't1');
    expect(notified, 2);
  });
}