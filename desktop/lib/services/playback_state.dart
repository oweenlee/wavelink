import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';

/// 续播持久化的 SharedPreferences key。集中定义，避免散落字符串。
const String kLastTrackId = 'lastTrackId';
const String kLastPositionMs = 'lastPositionMs';
const String kQueueIds = 'queueIds';

/// 重启续播的持久化快照：当前曲目 id + 播放进度 + 队列顺序。
///
/// 与 [PlayerController] 解耦，纯数据 + 编解码，便于单测。
class PlaybackSnapshot {
  final String trackId;
  final Duration position;
  final List<String> queueIds;

  const PlaybackSnapshot({
    required this.trackId,
    required this.position,
    required this.queueIds,
  });

  /// 从 SharedPreferences 读取；无 lastTrackId 时返回 null（表示无续播上下文）。
  static PlaybackSnapshot? fromPrefs(SharedPreferences prefs) {
    final trackId = prefs.getString(kLastTrackId);
    if (trackId == null) return null;
    final posMs = prefs.getInt(kLastPositionMs) ?? 0;
    final queueIds = prefs.getStringList(kQueueIds) ?? const <String>[];
    return PlaybackSnapshot(
      trackId: trackId,
      position: Duration(milliseconds: posMs),
      queueIds: queueIds,
    );
  }

  /// 写入 SharedPreferences（异步；调用方用 [unawaited] 包以 fire-and-forget）。
  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(kLastTrackId, trackId);
    await prefs.setInt(kLastPositionMs, position.inMilliseconds);
    await prefs.setStringList(kQueueIds, queueIds);
  }

  /// 清理全部续播 key（曲库已无该曲或用户清空全部数据时调用）。
  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(kLastTrackId);
    await prefs.remove(kLastPositionMs);
    await prefs.remove(kQueueIds);
  }
}

/// [restorePlayback] 的纯结果：待恢复的队列、当前索引、进度、以及首次
/// resume 时需 seek 到的位置。
class RestoredPlayback {
  final List<Track> queue;
  final int index;
  final Duration position;

  /// 启动后首次播放需 seek 到的进度；进度为 0 时为 null（从头播）。
  final Duration? pendingSeek;

  const RestoredPlayback({
    required this.queue,
    required this.index,
    required this.position,
    required this.pendingSeek,
  });
}

/// 纯函数：根据续播快照 + 当前曲库，推导待恢复的队列 / 当前索引 / 进度 / 待 seek。
///
/// 不依赖引擎、不碰 SharedPreferences 写入，因此可直接单测。分支：
/// - [snap] 为 null（无续播上下文）→ 返回 null；
/// - 快照指向的曲目已从曲库消失 → 返回 null（调用方据此清理残留）；
/// - 队列重建优先采用持久化顺序，曲库中已不存在的 id 被丢弃；
/// - 队列为空（无有效 id）→ 退化为整库顺序；
/// - 进度 > 0 则需续播 seek，否则从头播。
RestoredPlayback? restorePlayback(PlaybackSnapshot? snap, List<Track> library) {
  if (snap == null) return null;
  final track = library.where((t) => t.id == snap.trackId).firstOrNull;
  if (track == null) return null;

  final q = snap.queueIds
      .map((id) => library.where((t) => t.id == id).firstOrNull)
      .whereType<Track>()
      .toList();
  final queue = q.isNotEmpty ? q : library;
  final rawIndex = queue.indexOf(track);
  final index = rawIndex < 0 ? 0 : rawIndex;
  final pendingSeek = snap.position > Duration.zero ? snap.position : null;
  return RestoredPlayback(
    queue: queue,
    index: index,
    position: snap.position,
    pendingSeek: pendingSeek,
  );
}
