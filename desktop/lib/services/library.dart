import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/track.dart';
import 'scan_helpers.dart';

// 与网络音源共用同一扩展名白名单（scan_helpers.audioExtensions），
// 保证本地与 NAS/WebDAV 扫到的曲目集合一致（含 hi-res：APE/WV/DSF/DFF/ALAC）。
List<String> get _audioExtensions => audioExtensions;

/// 递归扫描目录，返回按 艺人→标题 排序的曲目列表（空目录返回空列表）。
/// 目录不存在 / 不可读 / 为空时返回空列表，由 UI 展示空库提示并引导用户
/// 「添加音乐文件夹」（用户添加的文件夹由 PlayerController 持久化）。
Future<List<Track>> scanFolder(String folderPath) async {
  final dir = Directory(folderPath);
  if (!await dir.exists()) return const [];

  final exts = _audioExtensions.toSet();
  final tracks = <Track>[];

  try {
    await for (final entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final lower = p.extension(entity.path).toLowerCase();
      if (!exts.contains(lower)) continue;
      try {
        final track = _parseTrack(entity);
        if (track != null) tracks.add(track);
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    // 权限拒绝（macOS 沙箱）或中途 I/O 失败：返回已扫到的部分，不崩 UI。
  }

  tracks.sort((a, b) {
    final c = a.artist.compareTo(b.artist);
    return c != 0 ? c : a.title.compareTo(b.title);
  });
  return tracks;
}

Track? _parseTrack(File file) {
  final name = p.basename(file.path);
  if (name.isEmpty) return null;

  // 文件名解析走 scan_helpers.parseArtistTitle（与网络音源共用同一实现，
  // 保证「艺人 - 标题」/「（艺人）标题」规则与未知艺人占位跨来源一致）。
  final (artist, title) = parseArtistTitle(name);

  // 查找同名 .lrc 歌词文件（同级目录，兼容大小写；都存在时优先小写）。
  String? lyricsPath;
  for (final ext in const ['.lrc', '.LRC']) {
    final candidate = '${p.withoutExtension(file.path)}$ext';
    if (File(candidate).existsSync()) {
      lyricsPath = candidate;
      break;
    }
  }

  return Track(
    id: file.path,
    title: title,
    artist: artist,
    filePath: file.path,
    lyricsPath: lyricsPath,
  );
}
