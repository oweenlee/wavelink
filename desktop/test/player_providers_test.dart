import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/player_notifier.dart';
import 'package:local_music_player/services/player_providers.dart';

/// playerProvider select 通知语义回归测试。
///
/// 历史 bug：provider 直接桥接 `StreamProvider<int?>` 的 indexStream，
/// 当两次 emit 的 index 相等（随机模式点歌恒为 0、playNext 插入后 index
/// 不变、不同视图同位索引），Riverpod 判定「无变化」跳过通知，右侧
/// 封面 / 列表高亮随之残留旧曲目。
///
/// 迁移到 `Notifier<PlayerState>` 后，UI 订阅 `select((s) => s.currentTrack?.id)`
/// ——select 按值比较，天然覆盖「同 index 不同曲目」场景，无需旧的
/// map-成新-Object hack。以下场景验证通知语义：曲目实际变化必通知、
/// 曲目未变（如 playNext 插队）不多余通知。
List<Track> mkTracks(int n) => List.generate(
    n,
    (i) => Track(
        id: 't$i', title: 'Track $i', artist: 'A$i', filePath: '/tmp/t$i.flac'));

void main() {
  late ProviderContainer container;
  late PlayerNotifier player;
  late int notified;

  setUp(() {
    container = ProviderContainer();
    player = container.read(playerProvider.notifier);
    notified = 0;
    container.listen(
      playerProvider.select((s) => s.currentTrack?.id),
      (_, _) => notified++,
    );
    addTearDown(container.dispose);
  });

  test('notifies on first track selection', () async {
    player.playFrom(mkTracks(3), 1);
    expect(player.state.currentTrack?.id, 't1');
    expect(notified, 1);
  });

  test('notifies when switching to a different track at the same index',
      () async {
    final ts = mkTracks(3);
    player.playFrom(ts, 1);
    // 同一队列位置 1，但队列内容变化（不同曲目顶上）
    player.playFrom([ts[2], ts[0], ts[1]], 1);
    expect(player.state.queueIndex, 1);
    expect(player.state.currentTrack?.id, 't0');
    // 旧实现此处 index 1 == 1 跳过通知，UI 封面/高亮会残留旧曲目
    expect(notified, 2);
  });

  test('shuffle mode: clicking another track still notifies (index stays 0)',
      () async {
    final ts = mkTracks(5);
    await player.toggleShuffle();
    player.playFrom(ts, 2); // 随机队列：t2 置首，index 0
    expect(player.state.currentTrack?.id, 't2');
    player.playFrom(ts, 4); // 再点 t4：重新洗牌，t4 置首，index 仍 0
    expect(player.state.queueIndex, 0);
    expect(player.state.currentTrack?.id, 't4');
    expect(notified, 2);
  });

  test('playNext while playing does not notify (current track unchanged)',
      () async {
    final ts = mkTracks(3);
    player.playFrom(ts, 0);
    player.playNext(ts[2]);
    expect(player.state.queueIndex, 0);
    expect(player.state.currentTrack?.id, 't0');
    // 当前曲目未变，select 按值比较不触发重建——这正是想要的精细订阅
    expect(notified, 1);
  });

  test('next() to a new track notifies', () async {
    final ts = mkTracks(3);
    player.playFrom(ts, 0);
    await player.next();
    expect(player.state.queueIndex, 1);
    expect(player.state.currentTrack?.id, 't1');
    expect(notified, 2);
  });
}
