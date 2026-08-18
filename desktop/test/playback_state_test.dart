import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/playback_state.dart';

Track _t(String id, {Duration? durationHint}) => Track(
      id: id,
      title: id.toUpperCase(),
      artist: 'artist',
      source: TrackSource.local,
      durationHint: durationHint,
    );

void main() {
  group('restorePlayback（纯恢复逻辑）', () {
    final a = _t('a');
    final b = _t('b');
    final c = _t('c');
    final library = [a, b, c];

    test('无快照 → 返回 null', () {
      expect(restorePlayback(null, library), isNull);
    });

    test('快照指向的曲已从曲库消失 → 返回 null（调用方据此清理）', () {
      final snap = PlaybackSnapshot(
        trackId: 'ghost',
        position: Duration.zero,
        queueIds: const [],
      );
      expect(restorePlayback(snap, library), isNull);
    });

    test('正常恢复：队列顺序 / 当前索引 / 进度 / 待 seek', () {
      final snap = PlaybackSnapshot(
        trackId: 'b',
        position: const Duration(seconds: 30),
        queueIds: const ['a', 'b', 'c'],
      );
      final r = restorePlayback(snap, library)!;
      expect(r.queue.map((t) => t.id).toList(), ['a', 'b', 'c']);
      expect(r.index, 1); // 当前曲是 b
      expect(r.position, const Duration(seconds: 30));
      expect(r.pendingSeek, const Duration(seconds: 30)); // 进度>0 → 需续播 seek
    });

    test('队列里已不存在的 id 被丢弃、其余保序', () {
      final snap = PlaybackSnapshot(
        trackId: 'c',
        position: Duration.zero,
        queueIds: const ['a', 'gone', 'c'], // 'gone' 不在曲库
      );
      final r = restorePlayback(snap, library)!;
      expect(r.queue.map((t) => t.id).toList(), ['a', 'c']);
      expect(r.index, 1); // 当前曲 c 在新队列里的下标
    });

    test('队列快照为空 → 退化为整库顺序', () {
      final snap = PlaybackSnapshot(
        trackId: 'a',
        position: Duration.zero,
        queueIds: const [],
      );
      final r = restorePlayback(snap, library)!;
      expect(r.queue.map((t) => t.id).toList(), ['a', 'b', 'c']);
      expect(r.index, 0);
    });

    test('进度为 0 → pendingSeek 为 null（从头播）', () {
      final snap = PlaybackSnapshot(
        trackId: 'a',
        position: Duration.zero,
        queueIds: const ['a'],
      );
      final r = restorePlayback(snap, library)!;
      expect(r.position, Duration.zero);
      expect(r.pendingSeek, isNull);
    });
  });

  group('PlaybackSnapshot 持久化往返', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('save 后 fromPrefs 能还原', () async {
      final p = await SharedPreferences.getInstance();
      final snap = PlaybackSnapshot(
        trackId: 'a',
        position: const Duration(seconds: 42),
        queueIds: const ['a', 'b', 'c'],
      );
      await snap.save(p);

      final back = PlaybackSnapshot.fromPrefs(p)!;
      expect(back.trackId, 'a');
      expect(back.position, const Duration(seconds: 42));
      expect(back.queueIds, ['a', 'b', 'c']);
    });

    test('无 lastTrackId 时 fromPrefs 返回 null', () async {
      final p = await SharedPreferences.getInstance();
      expect(PlaybackSnapshot.fromPrefs(p), isNull);
    });

    test('clear 删除全部三个 key', () async {
      final p = await SharedPreferences.getInstance();
      await PlaybackSnapshot(
        trackId: 'a',
        position: const Duration(seconds: 1),
        queueIds: const ['a'],
      ).save(p);
      expect(PlaybackSnapshot.fromPrefs(p), isNotNull);

      await PlaybackSnapshot.clear(p);
      expect(PlaybackSnapshot.fromPrefs(p), isNull);
      expect(p.getStringList(kQueueIds), isNull);
    });
  });
}
