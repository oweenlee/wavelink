import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/player_controller.dart';

/// PlayerController 状态机单测（不依赖 Rust 引擎 / SharedPreferences：
/// 引擎未 init 时为 null → 播放调用变 no-op，仅验证纯 Dart 队列逻辑）。
List<Track> mkTracks(int n) => List.generate(
    n,
    (i) => Track(
        id: 't$i', title: 'Track $i', artist: 'A$i', filePath: '/tmp/t$i.flac'));

/// 把模式循环到目标值（off → all → one → off ...）。
Future<void> setRepeat(PlayerController c, RepeatMode mode) async {
  for (var i = 0; i < RepeatMode.values.length; i++) {
    if (c.repeatMode == mode) return;
    await c.cycleRepeat();
  }
  throw StateError('unreachable');
}

void main() {
  late PlayerController c;

  setUp(() {
    c = PlayerController();
  });

  group('playFrom / playIndex', () {
    test('sets queue and index, current track follows', () {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      expect(c.currentIndex, 1);
      expect(c.currentTrack?.id, 't1');
    });

    test('shuffle puts the picked track first and keeps all tracks', () async {
      final ts = mkTracks(5);
      await c.toggleShuffle();
      c.playFrom(ts, 3);
      expect(c.currentIndex, 0);
      expect(c.currentTrack?.id, 't3');
      final queueIds = c.queue.map((t) => t.id).toSet();
      expect(queueIds.length, 5); // 无丢失、无重复
    });
  });

  group('next / previous', () {
    test('advances sequentially', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 0);
      await c.next();
      expect(c.currentIndex, 1);
      await c.next();
      expect(c.currentIndex, 2);
    });

    test('repeat all wraps to first', () async {
      final ts = mkTracks(2);
      c.playFrom(ts, 1);
      await setRepeat(c, RepeatMode.all);
      await c.next();
      expect(c.currentIndex, 0);
    });

    test('repeat one stays on the same track', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await setRepeat(c, RepeatMode.one);
      await c.next();
      expect(c.currentIndex, 1);
    });

    test('repeat off stops at the end', () async {
      final ts = mkTracks(2);
      c.playFrom(ts, 1);
      expect(c.repeatMode, RepeatMode.off);
      await c.next();
      expect(c.isPlaying, false);
    });

    test('previous goes back one track', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 2);
      await c.previous();
      expect(c.currentIndex, 1);
    });

    test('previous within first 3s of a track goes to the prior track',
        () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await c.previous(); // position == 0 (<3s) → 上一首
      expect(c.currentIndex, 0);
    });
  });

  group('playNext', () {
    test('inserts right after the current track', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 0);
      await c.next(); // index 1
      final extra = mkTracks(1).first;
      c.playNext(extra);
      expect(c.queue[1].id, 't1'); // 当前曲不动
      expect(c.queue[2].id, extra.id); // 紧随其后
      expect(c.queue[3].id, 't2');
    });

    test('on empty queue starts playing the track', () {
      final t = mkTracks(1).first;
      c.playNext(t);
      expect(c.currentIndex, 0);
      expect(c.currentTrack?.id, t.id);
    });

    test('shuffle mode: base queue insertion uses the base position',
        () async {
      final ts = mkTracks(4);
      await c.toggleShuffle();
      c.playFrom(ts, 2); // current = t2, queue index 0
      final extra =
          Track(id: 'extra', title: 'E', artist: 'E', filePath: '/tmp/e.flac');
      c.playNext(extra);
      // 播放队列：紧跟当前曲目
      expect(c.queue[0].id, 't2');
      expect(c.queue[1].id, 'extra');
      // 基准队列：插在原列表 t2 的后一个位置（而非复用队列下标盲插）
      final baseIds = c.queueBase.map((t) => t.id).toList();
      expect(baseIds.indexOf('extra'), baseIds.indexOf('t2') + 1);
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
      expect(c.library.length, 3);
    });
  });

  group('toggleShuffle keeps the current track', () {
    test('on and off preserve what is playing', () async {
      final ts = mkTracks(4);
      c.playFrom(ts, 1);
      await c.toggleShuffle();
      expect(c.currentTrack?.id, 't1');
      expect(c.currentIndex, 0);
      await c.toggleShuffle();
      expect(c.currentTrack?.id, 't1');
      expect(c.currentIndex, 1);
    });
  });

  group('isStreamDurationJitter', () {
    test('accepts small convergent corrections', () {
      // 渐进收敛每次修正步子小，不应被误判为噪声
      expect(PlayerController.isStreamDurationJitter(300_000, 310_000), isFalse);
      expect(PlayerController.isStreamDurationJitter(300_000, 350_000), isFalse);
      expect(PlayerController.isStreamDurationJitter(300_000, 300_000), isFalse);
      expect(PlayerController.isStreamDurationJitter(300_000, 290_000), isFalse);
    });

    test('rejects startup/seek instantaneous-rate jumps', () {
      // 开播/seek 后用瞬时拉速估算的时长可能偏差数倍，必须拒掉
      expect(PlayerController.isStreamDurationJitter(300_000, 60_000), isTrue);
      expect(PlayerController.isStreamDurationJitter(300_000, 800_000), isTrue);
      expect(PlayerController.isStreamDurationJitter(300_000, 100_000), isTrue);
      expect(PlayerController.isStreamDurationJitter(300_000, 480_000), isTrue);
    });

    test('unknown duration (0) is never rejected', () {
      expect(PlayerController.isStreamDurationJitter(0, 60_000), isFalse);
      expect(PlayerController.isStreamDurationJitter(0, 300_000), isFalse);
    });
  });

  tearDown(() async {
    await c.dispose();
  });
}
