import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../data/services/log.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../domain/models/song.dart';
import '../../../core/providers/repositories.dart';

/// 封面提取调度：从 LibraryNotifier 拆出的独立职责单元。
///
/// 两条提取通道：
/// - NAS 索引歌（无本地文件）：远端读头部提取（[extractNasCovers]）；
/// - 有本地文件的歌：Rust 引擎读取提取（[extractLocalCovers]）。
///
/// 提取完成通过 [onCoversUpdated] 回调通知上层刷新 UI 并持久化
/// （Song.coverUrl 为可变字段，需上层重建 state 触发监听）。
class CoverService {
  CoverService(this._ref, {this.onCoversUpdated});

  final Ref _ref;

  /// 封面就绪回调（上层刷新 UI + 持久化曲库）
  final VoidCallback? onCoversUpdated;

  /// NAS 远端封面批量提取（限流并发 4），完成后回调刷新。
  /// 失败静默：封面保持纯色占位，不影响曲库。
  /// 每批前先探活：发现死连接先重建，避免整批请求同时踩
  /// 死连接各白等超时；会话不可用则中止剩余批次，下轮扫描再提。
  /// 待提取队列（防重入 + 续跑）：多次触发（启动恢复/扫描完成）合并，
  /// 已拿到封面的歌自动剔除。
  final List<Song> _nasQueue = [];
  bool _extractingNas = false;

  /// 单曲连续失败计数：提取 3 轮仍无封面（真无封面/格式不支持）→ 放弃
  /// 保持占位色，避免永远留在队列里被无限重试。
  final Map<String, int> _nasFailCount = {};

  /// NAS 封面提取：低优先级后台任务，播放/下载时让路但**自动续跑**
  /// （历史问题：让路 break 后整个提取永久退出，剩余封面再也不提，
  /// 表现为"封面没有全解析出来"）。
  ///
  /// 并发 2（串行太慢：数百首歌每首一次 SMB 读头+解析，单并发要几分钟；
  /// 4 并发曾触发 NAS 连接数限制导致整批超时）。播放让路 + 熔断冷却
  /// 保护仍保留，配合续跑循环在播放间隙自动补齐。
  Future<void> extractNasCovers(List<Song> songs) async {
    if (songs.isEmpty) return;
    _nasQueue.addAll(songs);
    if (_extractingNas) return; // 已有提取循环在跑，新请求已并入队列
    _extractingNas = true;
    try {
      var idleRounds = 0; // 连续无进展轮数（会话死亡/熔断冷却），超限停止避免空转
      while (true) {
        final pending = pendingNasCovers(_nasQueue);
        if (pending.isEmpty) {
          _nasQueue.clear();
          break;
        }
        final progressed = await _extractNasPass(pending);
        // 本轮已成功的从队列剔除；连续 3 轮无封面（真无封面/格式不支持）
        // 也剔除，避免无限重试
        _nasQueue.removeWhere((s) =>
            s.coverUrl != null || (_nasFailCount[s.id] ?? 0) >= 3);
        if (progressed) {
          idleRounds = 0;
        } else {
          idleRounds++;
          if (idleRounds >= 8) {
            Log.w('Cover', '封面提取连续无进展，暂停续跑（剩余 ${pendingNasCovers(_nasQueue).length}）');
            break;
          }
        }
        // 播放让路/熔断冷却/失败后：等 15s 再续（播放间隙自动补齐）
        await Future.delayed(const Duration(seconds: 15));
      }
    } finally {
      _extractingNas = false;
    }
    onCoversUpdated?.call();
  }

  /// 单轮提取：并发 2，播放/下载活跃或会话不可用时让路返回。
  /// 返回本轮是否有进展（至少解析出一张封面）。
  Future<bool> _extractNasPass(List<Song> songs) async {
    var progressed = false;
    for (var i = 0; i < songs.length; i += 2) {
      // 播放/下载进行中：让路（不打断播放），由外层循环稍后继续
      if (SmbService.playbackActive) {
        Log.d('Cover', '播放/下载活跃，暂停封面提取（已完成 $i/${songs.length}）');
        return progressed || i > 0;
      }
      // 熔断冷却中：本轮跳过（未尝试不算失败，避免冷却轮误计单曲失败）
      if (SmbService.coverCooldownActive) {
        Log.d('Cover', '封面提取冷却中，本轮跳过（已完成 $i/${songs.length}）');
        return progressed || i > 0;
      }
      if (!await SmbService.ensureHealthy()) {
        Log.w('Cover', '会话不可用，中止本轮封面提取（已完成 $i/${songs.length}）');
        return progressed || i > 0;
      }
      final end = (i + 2 > songs.length) ? songs.length : i + 2;
      final batch = songs.sublist(i, end);
      await Future.wait(batch.map((s) => SmbService.fetchRemoteCover(s)));
      for (final s in batch) {
        if (s.coverUrl != null) {
          _nasFailCount.remove(s.id);
          progressed = true;
        } else {
          final c = (_nasFailCount[s.id] ?? 0) + 1;
          _nasFailCount[s.id] = c;
          if (c >= 3) {
            Log.d('Cover', '3 轮无封面，放弃提取: ${s.title}');
          }
        }
      }
    }
    return progressed;
  }

  /// 本地文件封面批量提取（限流并发 4，避免打满 FRB 线程池），
  /// 完成后有变更才回调刷新。
  Future<void> extractLocalCovers(List<Song> songs) async {
    final engineRepo = _ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/.covers');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

    // 待处理的歌曲（无封面缓存、本地文件真实存在）。
    // 不依赖 hasCover 标记（_fileToSong 降级导入时未设）；
    // NAS 缓存路径的本地文件可能已被清理/未下载 → 跳过，
    // 避免 lofty 读取不存在的文件（No such file or directory）。
    final pending = <Song>[];
    for (final s in songs) {
      if (s.path == null || s.coverUrl != null) continue;
      if (!await File(s.path!).exists()) continue;
      pending.add(s);
    }
    if (pending.isEmpty) return;

    var changed = false;
    const batchSize = 4;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(
        i,
        i + batchSize > pending.length ? pending.length : i + batchSize,
      );
      await Future.wait(batch.map((song) async {
        final cacheFile = File('${cacheDir.path}/${song.path!.hashCode}.jpg');
        if (await cacheFile.exists()) {
          song.coverUrl = cacheFile.path;
          changed = true;
          return;
        }
        try {
          final bytes = await engineRepo.getCoverBytes(song.path!);
          await cacheFile.writeAsBytes(bytes);
          song.coverUrl = cacheFile.path;
          changed = true;
        } catch (e) {
          Log.e('Cover', '提取封面失败: $e');
        }
      }));
    }
    if (changed) onCoversUpdated?.call();
  }

  /// 筛选缺封面的 NAS 索引歌（无本地文件，需远端读头提取）
  static List<Song> pendingNasCovers(List<Song> songs) => songs
      .where((s) => s.smbPath != null && s.path == null && s.coverUrl == null)
      .toList();

  /// 筛选缺封面且有本地文件的歌（从文件提取）
  static List<Song> pendingLocalCovers(List<Song> songs) =>
      songs.where((s) => s.path != null && s.coverUrl == null).toList();
}
