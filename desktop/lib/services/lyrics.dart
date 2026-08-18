import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../src/rust/api/smb.dart' as frb_smb;
import 'nas_service.dart';
import 'webdav_service.dart';

class LyricLine {
  final Duration time;
  final String text;

  LyricLine(this.time, this.text);
}

/// Parse a standard .lrc file into time-sorted lyric lines.
/// Supports multiple timestamps per line, e.g. `[00:12.34][00:50.00]text`.
List<LyricLine> parseLrc(String content) {
  final timeTag = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  final Map<Duration, String> map = {};

  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final matches = timeTag.allMatches(line);
    if (matches.isEmpty) continue;

    final text = line.replaceAll(timeTag, '').trim();
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      final fracRaw = m.group(3) ?? '0';
      // group(3) may be milliseconds (3 digits) or centiseconds (2 digits)
      final frac = int.parse(fracRaw.padRight(3, '0').substring(0, 3));
      final time = Duration(minutes: min, seconds: sec, milliseconds: frac);
      map[time] = text;
    }
  }

  final lines = map.entries
      .map((e) => LyricLine(e.key, e.value))
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// Load and parse the .lrc sibling of a track, if present.
Future<List<LyricLine>> loadLyrics(String? lyricsPath) async {
  if (lyricsPath == null) return const [];
  try {
    final file = File(lyricsPath);
    if (!await file.exists()) return const [];
    return parseLrc(decodeLrcBytes(await file.readAsBytes()));
  } catch (e) {
    debugPrint('loadLyrics error: $e');
    return const [];
  }
}

/// 按音源加载歌词（对齐 mobile）：
/// - local：同级 .lrc 文件（[Track.lyricsPath]）
/// - nas：SMB 远程同名 .lrc/.LRC（[Track.remotePath]）
/// - webdav：WebDAV 远程同名 .lrc/.LRC（[Track.remotePath]）
/// - subsonic：暂不支持（mobile 同样未实现）
///
/// 远程歌词缓存到 `<文档>/.lrc_cache/<hash>.lrc`，避免每次播放重复拉网络。
Future<List<LyricLine>> loadLyricsFor(Track t) async {
  switch (t.source) {
    case TrackSource.local:
      return loadLyrics(t.lyricsPath);
    case TrackSource.nas:
      if (t.remotePath == null) return const [];
      return _loadCachedOrFetch(
        t.remotePath!,
        () => fetchNasLyrics(t.remotePath!),
      );
    case TrackSource.webdav:
      if (t.remotePath == null) return const [];
      return _loadCachedOrFetch(
        t.remotePath!,
        () => fetchWebdavLyrics(t.remotePath!),
      );
    case TrackSource.subsonic:
      return const [];
  }
}

/// NAS(SMB) 远端歌词：与音频同目录同名的 .lrc/.LRC，全部读取并解码。
Future<String?> fetchNasLyrics(String smbPath) async {
  // 确保 SMB 会话可用（内部 keepalive 探测，不健康则重建）
  if (await NasService.connect() != null) return null;
  final base = smbPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
  for (final ext in const ['.lrc', '.LRC']) {
    try {
      final bytes = await frb_smb.smbReadFile(path: '$base$ext');
      if (bytes.isEmpty) continue;
      return decodeLrcBytes(bytes);
    } catch (_) {
      // 文件不存在 / 读取失败：尝试下一个扩展名
    }
  }
  return null;
}

/// WebDAV 远端歌词：与音频同目录同名的 .lrc/.LRC，全量读取并解码。
Future<String?> fetchWebdavLyrics(String davPath) async {
  final base = davPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
  for (final ext in const ['.lrc', '.LRC']) {
    final bytes = await WebdavService.readRemoteBytes('$base$ext');
    if (bytes == null || bytes.isEmpty) continue;
    return decodeLrcBytes(bytes);
  }
  return null;
}

/// 远程歌词缓存读写：命中缓存直接解析，否则拉取并落盘。
Future<List<LyricLine>> _loadCachedOrFetch(
  String key,
  Future<String?> Function() fetch,
) async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheFile = File('${appDir.path}/.lrc_cache/${key.hashCode}.lrc');
    if (await cacheFile.exists()) {
      final parsed = parseLrc(await cacheFile.readAsString());
      if (parsed.isNotEmpty) return parsed;
    }
    final text = await fetch();
    if (text == null || text.trim().isEmpty) return const [];
    final parsed = parseLrc(text);
    if (parsed.isNotEmpty) {
      final dir = cacheFile.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await cacheFile.writeAsString(text);
    }
    return parsed;
  } catch (e) {
    debugPrint('loadLyricsFor error: $e');
    return const [];
  }
}

/// 字节 → 文本：先严格 UTF-8（合法序列原样通过），失败回退 GBK，
/// 再失败回落宽松 UTF-8。对齐 mobile `lrc_codec.dart`：中文歌词库
/// （群晖/Nextcloud 等）大量 `.lrc` 是 GBK/GB2312 编码，宽松 UTF-8 会把
/// GBK 高位双字节“硬解”成乱码；严格模式拒绝非法 UTF-8 序列以可靠触发回退。
/// 前置剥离 UTF-8 BOM（Windows 记事本保存的 .lrc 带 BOM）。
String decodeLrcBytes(Uint8List bytes) {
  var data = bytes;
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    data = data.sublist(3);
  }
  try {
    return utf8.decode(data);
  } on FormatException {
    try {
      return gbk.decode(data);
    } catch (_) {
      // 极端兜底：GBK 也失败时回到宽松 UTF-8，保证不抛异常
      return utf8.decode(data, allowMalformed: true);
    }
  }
}

/// Find the index of the lyric line active at [position].
int activeLyricIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty) return -1;
  int lo = 0, hi = lines.length - 1, res = -1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    if (lines[mid].time <= position) {
      res = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return res;
}