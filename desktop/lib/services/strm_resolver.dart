library;

/// STRM 指针解析（桌面端，从 mobile `strm_resolver` 移植，去除 Song 依赖）。
///
/// `.strm` 是 Kodi / Jellyfin / Emby 的「流媒体桩文件」：本体是文本，内含一行
/// 真实媒体目标（源内相对路径或 http(s) URL）。扫描期落地、播放前解析分发。
///
/// 四类目标：
/// - `smb`：源内相对路径（strm 所在源为 NAS/SMB）→ 走 SMB 流
/// - `dav`：源内相对路径（strm 所在源为 WebDAV）→ 走 WebDAV 流
/// - `http`：带音频扩展名的完整 URL → 文件流（下载或流式）
/// - `stream`：无扩展名 URL（网络电台流）→ 无限流
import 'scan_helpers.dart';

/// STRM 解析结果（Resolver 层产出，Scanner 扫描落地 / Player 兜底共用）。
class StrmTarget {
  /// 目标类型：smb / dav / http / stream。
  final String kind;

  /// 已规范化的源内相对路径或完整 URL。
  final String path;

  /// Kodi 风格 `#EXTINF:秒数,标题` 信息行携带的展示标题。
  final String? extInfTitle;

  /// Kodi 风格 `#EXTINF` 信息行携带的时长（秒）。
  final int? extInfSecs;

  const StrmTarget({
    required this.kind,
    required this.path,
    this.extInfTitle,
    this.extInfSecs,
  });
}

/// 是否为 STRM 指针文件名（大小写不敏感）。
bool isStrmName(String name) => name.split('.').last.toLowerCase() == 'strm';

/// 解析 STRM 文本内容 → 目标媒体。
///
/// [fromWebdav]：strm 文件所在源（决定相对路径目标的 kind 与读取通道）。
/// [strmPath]：strm 文件在源内的路径（相对路径目标按它所在目录解析）。
/// 解析失败（无有效目标 / 目标非音频扩展名）返回 null。
///
/// 兼容格式（与 Kodi / Jellyfin 对齐）：
/// - 去 BOM / 空白 / `#` 注释行，取第一行有效内容（多行 strm 只取首行）
/// - `#EXTINF:秒数,标题` 信息行携带展示标题/时长（Kodi 风格 strm 库）
/// - `http(s)://` 完整 URL：带音频扩展名 → http；无扩展名（电台流）→ stream
/// - 相对路径：`/` 开头视为相对库根，否则相对 strm 文件所在目录，规范化 `./ ../`
StrmTarget? parseStrmContent(
  String text, {
  required bool fromWebdav,
  required String strmPath,
}) {
  int? extInfSecs;
  String? extInfTitle;
  String? line;
  for (final raw in text.split('\n')) {
    final l = raw.trim().replaceFirst('﻿', '');
    if (l.isEmpty) continue;
    if (l.startsWith('#')) {
      if (l.startsWith('#EXTINF:')) {
        final body = l.substring('#EXTINF:'.length);
        final comma = body.indexOf(',');
        if (comma > 0) {
          final secs = int.tryParse(body.substring(0, comma).trim());
          if (secs != null && secs > 0) extInfSecs = secs;
          final t = body.substring(comma + 1).trim();
          if (t.isNotEmpty) extInfTitle = t;
        }
      }
      continue;
    }
    line = l;
    break;
  }
  if (line == null) return null;

  if (line.startsWith('http://') || line.startsWith('https://')) {
    // 带音频扩展名 → http（文件型 URL）；无扩展名 → stream（网络电台流）
    final ext = strmExtFromUrl(line);
    final extName = ext.startsWith('.') ? ext.substring(1) : ext;
    if (audioExtensions.contains('.$extName')) {
      return StrmTarget(
        kind: 'http',
        path: line,
        extInfTitle: extInfTitle,
        extInfSecs: extInfSecs,
      );
    }
    // 识别不到已知音频扩展名：仅 URL path 真无扩展名（电台流）才允许
    // 走 stream；带非音频扩展名（.txt/.mkv 等）一律拒绝
    final uriPath = Uri.tryParse(line)?.path ?? '';
    final lastSlash = uriPath.lastIndexOf('/');
    final lastDot = uriPath.lastIndexOf('.');
    final hasRealExt = lastDot > lastSlash && lastDot < uriPath.length - 1;
    if (hasRealExt) return null;
    return StrmTarget(
      kind: 'stream',
      path: line,
      extInfTitle: extInfTitle,
      extInfSecs: extInfSecs,
    );
  }

  // 相对路径：以 "/" 开头视为相对库根（strmPath 语义为源内相对路径），
  // 否则相对 strm 文件所在目录（如 strm 与媒体同目录时内容为文件名）。
  final slash = strmPath.lastIndexOf('/');
  final dir = slash > 0 ? strmPath.substring(0, slash) : '';
  final raw = line.startsWith('/')
      ? line.substring(1)
      : (dir.isEmpty ? line : '$dir/$line');
  final target = normalizeRelPath(raw);
  if (target.isEmpty) return null;
  final ext = target.split('.').last.toLowerCase();
  if (!audioExtensions.contains('.$ext')) return null;
  return StrmTarget(
    kind: fromWebdav ? 'dav' : 'smb',
    path: target,
    extInfTitle: extInfTitle,
    extInfSecs: extInfSecs,
  );
}

/// 从 URL 提取音频扩展名（带点，如 `.flac`）；识别不到返回 `.audio`。
/// 播放缓存文件名与 STRM 目标分类共用。
String strmExtFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '.audio';
  final path = uri.path.toLowerCase();
  for (final ext in [
    '.flac',
    '.wav',
    '.mp3',
    '.aac',
    '.ogg',
    '.m4a',
    '.opus',
    '.dsf',
    '.dff',
    '.aiff',
    '.ape',
    '.wv',
  ]) {
    if (path.endsWith(ext)) return ext;
  }
  return '.audio';
}

/// 规范化相对路径：解析 "./" 与 "../"，去除冗余分隔符。
String normalizeRelPath(String p) {
  final parts = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}
