import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'stable_hash.dart';

/// 缓存孤儿清理：删除曲库中已不存在的曲目对应的缓存文件。
///
/// 各缓存目录的文件命名规则（与各 service 保持一致）：
/// - `.covers/<filePath 的 fnv1a>.jpg`，filePath 为 null 时（网络源曲目）为 `<track.id>.jpg`
/// - `.webdav_cache/<davPath 的 fnv1a>_<name>`，库中 id 前缀为 `dav_`
/// - `.nas_cache/<smbPath 的 fnv1a>_<name>`，库中 id 前缀为 `nas_`
/// - `.subsonic_cache/<fnv1a(id)><ext>`，文件名前段即 track.id 的 fnv1a
/// - `.lrc_cache` 键为歌词源 URL，与 track 无 id 映射，不参与清理
///
/// 注意：covers 集合必须覆盖所有来源（local 与网络源），网络源曲目
/// filePath 为 null 时封面键就是 track.id，若只收集本地曲目会把网络源
/// 封面缓存全部误删。
class CacheCleaner {
  CacheCleaner._();

  /// 依据当前曲库 [tracks] 清理各缓存目录的孤儿文件。
  static Future<void> cleanOrphans(List<Track> tracks) async {
    final appDir = await getApplicationDocumentsDirectory();

    final covers = <String>{};
    final webdav = <String>{};
    final nas = <String>{};
    final subsonic = <String>{};

    for (final t in tracks) {
      // covers 键与 CoverCache._keyFor 对齐：filePath 为 null 时（网络源曲目）
      // 用 track.id 作键，本地曲目用 filePath 的 fnv1a。两种都保留，
      // 避免已下载曲目 filePath 变化后旧封面被误删。
      covers.add(t.id);
      if (t.filePath != null) covers.add(fnv1a(t.filePath!));
      switch (t.source) {
        case TrackSource.webdav:
          if (t.id.startsWith('dav_')) webdav.add(t.id.substring(4));
        case TrackSource.nas:
          if (t.id.startsWith('nas_')) nas.add(t.id.substring(4));
        case TrackSource.subsonic:
          subsonic.add(fnv1a(t.id));
        case TrackSource.local:
          break;
      }
    }

    await _prune(p.join(appDir.path, '.covers'), covers, splitOn: '.');
    await _prune(p.join(appDir.path, '.webdav_cache'), webdav, splitOn: '_');
    await _prune(p.join(appDir.path, '.nas_cache'), nas, splitOn: '_');
    await _prune(
        p.join(appDir.path, '.subsonic_cache'), subsonic, splitOn: '.');
  }

  /// 遍历 [dirPath] 下所有文件，文件名按 [splitOn] 切出的前段
  /// 不在 [keepPrefixes] 中则删除。`.part` 等中间文件沿用同名规则，
  /// 前缀命中即保留（可能正在下载），未命中一并清理。
  static Future<void> _prune(
    String dirPath,
    Set<String> keepPrefixes, {
    required String splitOn,
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      final prefix = name.split(splitOn).first;
      if (!keepPrefixes.contains(prefix)) {
        try {
          await e.delete();
        } catch (_) {
          // 文件被占用等：跳过，下次清理再试
        }
      }
    }
  }
}
