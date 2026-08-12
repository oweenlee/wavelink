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
  /// 串行提取（并发 1）：封面读头部会在池连接被占时新建独立 SMB 连接，
  /// 并发过高容易触发 NAS 连接数限制（历史事故：封面批在跑时点歌，
  /// 播放喂流拿不到连接 → 3s 超时杀流 → 回退下载又撞封面批，点歌 34s
  /// 才出声）。串行 + 播放让路把封面降到最低优先级。
  Future<void> extractNasCovers(List<Song> songs) async {
    for (var i = 0; i < songs.length; i++) {
      // 播放/下载进行中：让路，剩余封面下轮再提（不打断播放）
      if (SmbService.playbackActive) {
        Log.d('Cover', '播放/下载活跃，暂停封面提取（已完成 $i/${songs.length}）');
        break;
      }
      if (!await SmbService.ensureHealthy()) {
        Log.w('Cover', '会话不可用，中止剩余封面提取（已完成 $i/${songs.length}）');
        break;
      }
      await SmbService.fetchRemoteCover(songs[i]);
    }
    onCoversUpdated?.call();
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
