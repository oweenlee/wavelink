import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/player_notifier.dart';
import 'package:local_music_player/services/player_providers.dart';

/// PlayerNotifier 状态机单测（不依赖 Rust 引擎 / SharedPreferences：
/// 引擎未 init 时为 null → 播放调用变 no-op，仅验证纯 Dart 队列逻辑）。
/// Notifier 的 state 依赖 provider 容器，故经 ProviderContainer 取实例。
List<Track> mkTracks(int n) => List.generate(
    n,
    (i) => Track(
        id: 't$i', title: 'Track $i', artist: 'A$i', filePath: '/tmp/t$i.flac'));

/// 把模式循环到目标值（off → all → one → off ...）。
Future<void> setRepeat(PlayerNotifier c, RepeatMode mode) async {
  for (var i = 0; i < RepeatMode.values.length; i++) {
    if (c.state.repeatMode == mode) return;
    await c.cycleRepeat();
  }
  throw StateError('unreachable');
}

void main() {
  late ProviderContainer container;
  late PlayerNotifier c;

  setUp(() {
    container = ProviderContainer();
    c = container.read(playerProvider.notifier);
    addTearDown(container.dispose);
  });

  group('playFrom / playIndex', () {
    test('sets queue and index, current track follows', () {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      expect(c.state.queueIndex, 1);
      expect(c.state.currentTrack?.id, 't1');
    });

    test('shuffle puts the picked track first and keeps all tracks', () async {
      final ts = mkTracks(5);
      await c.toggleShuffle();
      c.playFrom(ts, 3);
      expect(c.state.queueIndex, 0);
      expect(c.state.currentTrack?.id, 't3');
      final queueIds = c.state.queue.map((t) => t.id).toSet();
      expect(queueIds.length, 5); // 无丢失、无重复
    });

    test('过期代数的播放收尾不回写已加载曲目（generation 守卫）', () async {
      final ts = mkTracks(2);
      // 正常播第一首：loaded = t0，代数 +1
      c.playFrom(ts, 0);
      await Future<void>.delayed(Duration.zero); // 让 playIndex 收尾跑完
      expect(c.loadedTrackIdForTest, 't0');
      final currentGen = c.playGenerationForTest;
      // 模拟快速连点竞态：旧调用（gen-1）在 await 后迟到收尾，
      // 守卫必须拒绝回写，当前曲目保持 t1 的 loaded 语义不被覆盖
      c.finishPlayForTest(currentGen - 1, ts[0]);
      expect(c.loadedTrackIdForTest, 't0');
      // 当前代数正常收尾则照常回写
      c.finishPlayForTest(currentGen, ts[1]);
      expect(c.loadedTrackIdForTest, 't1');
    });
  });

  group('next / previous', () {
    test('advances sequentially', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 0);
      await c.next();
      expect(c.state.queueIndex, 1);
      await c.next();
      expect(c.state.queueIndex, 2);
    });

    test('repeat all wraps to first', () async {
      final ts = mkTracks(2);
      c.playFrom(ts, 1);
      await setRepeat(c, RepeatMode.all);
      await c.next();
      expect(c.state.queueIndex, 0);
    });

    test('repeat one stays on the same track', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await setRepeat(c, RepeatMode.one);
      await c.next();
      expect(c.state.queueIndex, 1);
    });

    test('repeat off stops at the end', () async {
      final ts = mkTracks(2);
      c.playFrom(ts, 1);
      expect(c.state.repeatMode, RepeatMode.off);
      await c.next();
      expect(c.state.playing, false);
    });

    test('previous goes back one track', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 2);
      await c.previous();
      expect(c.state.queueIndex, 1);
    });

    test('previous within first 3s of a track goes to the prior track',
        () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await c.previous(); // position == 0 (<3s) → 上一首
      expect(c.state.queueIndex, 0);
    });
  });

  group('CUE 虚拟分轨', () {
    Track mkCue(int i, int total) => Track(
        id: '/tmp/a.cue#${i.toString().padLeft(2, '0')}',
        title: '轨 $i',
        artist: '某艺人',
        album: '整轨专辑',
        filePath: '/tmp/a.flac',
        trackNumber: i + 1,
        cuePath: '/tmp/a.cue',
        cueTrackIndex: i,
        cueTrackCount: total);

    test('cue 曲目入队/状态机与普通曲目同构（引擎缺失时安全 no-op）', () async {
      final ts = [mkCue(0, 3), mkCue(1, 3), mkCue(2, 3)];
      c.playFrom(ts, 1);
      expect(c.state.queueIndex, 1);
      expect(c.state.currentTrack!.isCueTrack, isTrue);
      await c.next();
      expect(c.state.queueIndex, 2);
      await c.previous();
      await c.previous(); // 进度为零 → 回上一轨
      expect(c.state.queueIndex, 0);
    });
  });


  group('favorites', () {
    test('toggle adds then removes (prefs absent → persist is no-op)',
        () async {
      final t = mkTracks(1).first;
      expect(c.isFavorite(t), false);
      await c.toggleFavorite(t);
      expect(c.isFavorite(t), true);
      await c.toggleFavorite(t);
      expect(c.isFavorite(t), false);
    });
  });

  group('library', () {
    test('addLibraryFiles dedupes by id', () {
      c.addLibraryFiles(mkTracks(3));
      c.addLibraryFiles(mkTracks(3)); // 同一批再来一次
      expect(c.state.library.length, 3);
    });
  });

  group('toggleShuffle keeps the current track', () {
    test('on and off preserve what is playing', () async {
      final ts = mkTracks(4);
      c.playFrom(ts, 1);
      await c.toggleShuffle();
      expect(c.state.currentTrack?.id, 't1');
      expect(c.state.queueIndex, 0);
      await c.toggleShuffle();
      expect(c.state.currentTrack?.id, 't1');
      expect(c.state.queueIndex, 1);
    });
  });

}
