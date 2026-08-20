import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/models/song.dart';
import 'log.dart';
import 'stable_hash.dart';

/// 缓存清理：统计与删除曲库中无引用的缓存文件。
///
/// 缓存的四类目录（均位于 Documents 沙盒内）：
/// - `.covers/`      封面缓存（`<hash>.jpg` / `smb_<hash>.jpg` / `dav_<hash>.jpg`）
/// - `.smb_cache/`   NAS 播放时下载的本地副本
/// - `.webdav_cache/`WebDAV 播放时下载的本地副本
/// - `.lrc_cache/`   NAS 远端歌词的本地缓存
///
/// 删除策略：只清「当前曲库无引用」的文件，正在使用/播放中的封面与
/// 下载文件不受影响；SQLite（曲库/收藏/播放历史）是数据不是缓存，不碰。
class CacheCleaner {
  static const _dirs = ['.covers', '.smb_cache', '.webdav_cache', '.lrc_cache'];

  /// 四类缓存目录的总字节数（仅统计，不判断引用）。
  static Future<int> computeCacheBytes() async {
    final appDir = await getApplicationDocumentsDirectory();
    var total = 0;
    for (final name in _dirs) {
      final dir = Directory('${appDir.path}/$name');
      if (!await dir.exists()) continue;
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    }
    return total;
  }

  /// 收集当前曲库引用的所有沙盒文件路径（引用集合）。
  static Future<Set<String>> collectReferencedFiles(List<Song> songs) async {
    final appDir = await getApplicationDocumentsDirectory();
    final prefix = '${appDir.path}/';
    final refs = <String>{};
    for (final s in songs) {
      void add(String? p) {
        if (p != null && p.startsWith(prefix)) refs.add(p);
      }

      add(s.path);
      add(s.coverUrl);
      add(s.lyricsPath);
      if (s.smbPath != null && s.smbPath!.isNotEmpty) {
        // NAS 远端歌词本地缓存，与 smb_service 命名一致
        add('$prefix.lrc_cache/${stableHash(s.smbPath!)}.lrc');
      }
      if (s.davPath != null && s.davPath!.isNotEmpty) {
        // WebDAV 下载缓存，与 webdav_service 命名一致
        add(
          '$prefix.webdav_cache/${stableHash(s.davPath!)}_${s.davPath!.split('/').last}',
        );
      }
    }
    return refs;
  }

  /// 删除四类缓存目录中不在 [referenced] 集合内的文件。
  /// 返回释放的总字节数。
  static Future<int> clearUnreferencedCache(Set<String> referenced) async {
    final appDir = await getApplicationDocumentsDirectory();
    var freed = 0;
    for (final name in _dirs) {
      final dir = Directory('${appDir.path}/$name');
      if (!await dir.exists()) continue;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || referenced.contains(e.path)) continue;
        try {
          freed += await e.length();
          await e.delete();
        } catch (err) {
          Log.e('CacheCleaner', '删除缓存失败: ${e.path} ($err)');
        }
      }
    }
    return freed;
  }

  /// 字节数人类可读格式化（与诊断页日志大小展示一致）。
  static String formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}
