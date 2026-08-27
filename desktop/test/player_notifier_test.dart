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

  group('playNext', () {
    test('inserts right after the current track', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 0);
      await c.next(); // index 1
      final extra = mkTracks(1).first;
      c.playNext(extra);
      expect(c.state.queue[1].id, 't1'); // 当前曲不动
      expect(c.state.queue[2].id, extra.id); // 紧随其后
      expect(c.state.queue[3].id, 't2');
    });

    test('on empty queue starts playing the track', () {
      final t = mkTracks(1).first;
      c.playNext(t);
      expect(c.state.queueIndex, 0);
      expect(c.state.currentTrack?.id, t.id);
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
      expect(c.state.queue[0].id, 't2');
      expect(c.state.queue[1].id, 'extra');
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

  group('queue view (removeFromQueueAt / clearQueue)', () {
    test('remove trailing track keeps index', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await c.removeFromQueueAt(2);
      expect(c.state.queue.length, 2);
      expect(c.state.queueIndex, 1);
      expect(c.state.currentTrack?.id, 't1');
    });

    test('remove track before current shifts index back', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await c.removeFromQueueAt(0);
      expect(c.state.queue.length, 2);
      expect(c.state.queueIndex, 0);
      expect(c.state.currentTrack?.id, 't1');
    });

    test('remove current track continues with next at same slot', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 1);
      await c.removeFromQueueAt(1);
      expect(c.state.queue.length, 2);
      expect(c.state.queueIndex, 1);
      expect(c.state.currentTrack?.id, 't2');
    });

    test('remove only track stops playback', () async {
      final ts = mkTracks(1);
      c.playFrom(ts, 0);
      await c.removeFromQueueAt(0);
      expect(c.state.queue, isEmpty);
      expect(c.state.queueIndex, isNull);
      expect(c.state.playing, isFalse);
    });

    test('clearQueue keeps only current track', () async {
      final ts = mkTracks(5);
      c.playFrom(ts, 2);
      await c.clearQueue();
      expect(c.state.queue.length, 1);
      expect(c.state.queue.single.id, 't2');
      expect(c.state.queueIndex, 0);
    });

    test('remove keeps queueBase in sync (no resurrect after shuffle)', () async {
      final ts = mkTracks(5);
      await c.toggleShuffle();
      c.playFrom(ts, 0);
      final removed = c.state.queue.last.id;
      await c.removeFromQueueAt(c.state.queue.length - 1);
      expect(c.queueBase.any((t) => t.id == removed), isFalse);
      await c.clearQueue();
      expect(c.queueBase.length, 1);
    });

    test('moveInQueue reorders and keeps queueIndex on non-current', () async {
      final ts = mkTracks(4);
      c.playFrom(ts, 1); // queue=[t0,t1,t2,t3] qi=1
      await c.moveInQueue(0, 2); // t0 拖到 t2 前 → [t1,t2,t0,t3]
      expect(c.state.queue.map((t) => t.id).toList(), ['t1', 't2', 't0', 't3']);
      // t0 从当前曲(qi=1)之前拖到之后：当前曲前移一位
      expect(c.state.queueIndex, 0);
      expect(c.queueBase.map((t) => t.id).toList(), ['t1', 't2', 't0', 't3']);
    });

    test('moveInQueue moves current track and follows index', () async {
      final ts = mkTracks(4);
      c.playFrom(ts, 1); // qi=1
      await c.moveInQueue(1, 3); // 拖当前曲到末尾 → [t0,t2,t3,t1]
      expect(c.state.queue.map((t) => t.id).toList(), ['t0', 't2', 't3', 't1']);
      expect(c.state.queueIndex, 3); // 当前曲跟着走
    });

    test('moveInQueue drag across current shifts index correctly', () async {
      final ts = mkTracks(4);
      c.playFrom(ts, 2); // qi=2
      // t0 拖到 qi 之后：当前曲前移一位
      await c.moveInQueue(0, 3); // [t1,t2,t3,t0]
      expect(c.state.queue.map((t) => t.id).toList(), ['t1', 't2', 't3', 't0']);
      expect(c.state.queueIndex, 1);
      // 再拖回 qi 之前（t0 从末尾拖到最前）：当前曲后移一位
      await c.moveInQueue(3, 0); // [t0,t1,t2,t3]
      expect(c.state.queue.map((t) => t.id).toList(), ['t0', 't1', 't2', 't3']);
      expect(c.state.queueIndex, 2);
    });

    test('moveInQueue during shuffle only reorders play order', () async {
      final ts = mkTracks(4);
      await c.toggleShuffle();
      c.playFrom(ts, 0); // qi=0, queue 乱序
      final shuffledOrder = c.state.queue.map((t) => t.id).toList();
      expect(c.queueBase.map((t) => t.id).toList(), ['t0', 't1', 't2', 't3']);
      final from = 1, to = 3;
      await c.moveInQueue(from, to);
      final movedOrder = c.state.queue.map((t) => t.id).toList();
      expect(movedOrder.length, 4);
      // 期望 = 原乱序中把 index1 的曲移到 index3（移除后插入）
      final manual = [...shuffledOrder];
      final m = manual.removeAt(from);
      manual.insert(to, m);
      expect(movedOrder, manual);
      // base 不受影响
      expect(c.queueBase.map((t) => t.id).toList(), ['t0', 't1', 't2', 't3']);
    });

    test('moveInQueue bounds are no-ops', () async {
      final ts = mkTracks(3);
      c.playFrom(ts, 0);
      final before = c.state.queue.map((t) => t.id).toList();
      await c.moveInQueue(-1, 1);
      await c.moveInQueue(0, 5);
      await c.moveInQueue(1, 1);
      expect(c.state.queue.map((t) => t.id).toList(), before);
    });
  });

  group('playlist rename', () {
    test('renamePlaylist updates the name', () async {
      await c.createPlaylist('Old Name');
      final id = c.state.playlists.single.id;
      await c.renamePlaylist(id, 'New Name');
      expect(c.state.playlists.single.name, 'New Name');
    });

    test('renamePlaylist ignores blank name', () async {
      await c.createPlaylist('Old Name');
      final id = c.state.playlists.single.id;
      await c.renamePlaylist(id, '   ');
      expect(c.state.playlists.single.name, 'Old Name');
    });
  });
}
