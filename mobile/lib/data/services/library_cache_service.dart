import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/song.dart';
import 'log.dart';

/// 曲库列表的轻量持久化：整表 JSON 存 Documents/.library_cache.json
///
/// 歌曲列表变化（导入/扫描）时 fire-and-forget 写盘，
/// App 启动时读回恢复曲库，避免重启后一片空白。
///
/// 沙盒内路径（path/coverUrl/lyricsPath）以相对 Documents 的形式
/// 存储：iOS 重装/更新后数据容器目录会变（绝对路径全部失效），
/// 相对路径天然免疫。沙盒外路径（系统媒体库等）原样存绝对路径。
class LibraryCacheService {
  LibraryCacheService._();

  static const _fileName = '.library_cache.json';

  /// 写盘（失败静默，不影响主流程）
  static Future<void> saveSongs(List<Song> songs) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      final data = jsonEncode(
        songs.map((s) => _relativize(s.toJson(), dir.path)).toList(),
      );
      await file.writeAsString(data);
    } catch (e) {
      Log.e('LibraryCache', '保存失败: $e');
    }
  }

  /// 读回；文件不存在/损坏均返回空列表
  static Future<List<Song>> loadSongs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!await file.exists()) return [];
      final data = await file.readAsString();
      if (data.isEmpty) return [];
      final list = jsonDecode(data) as List<dynamic>;
      return list
          .map(
            (e) => Song.fromJson(
              _resolve(e as Map<String, dynamic>, dir.path),
            ),
          )
          .toList();
    } catch (e) {
      Log.e('LibraryCache', '读取失败: $e');
      return [];
    }
  }

  static const _pathKeys = ['path', 'coverUrl', 'lyricsPath'];

  /// 沙盒内绝对路径 → 相对路径（去掉 Documents 前缀）；
  /// 沙盒外路径（系统媒体库/ipod-library 等）原样保留。
  static Map<String, dynamic> _relativize(
    Map<String, dynamic> json,
    String docs,
  ) {
    for (final k in _pathKeys) {
      final v = json[k];
      if (v is String && v.startsWith('$docs/')) {
        json[k] = v.substring(docs.length + 1).replaceAll(RegExp(r'^/'), '');
      }
    }
    return json;
  }

  /// 相对路径 → 绝对路径（拼回当前 Documents 目录）。
  /// 兼容存量绝对路径数据：不以 '/' 开头且非 URL（ipod-library:// 等）
  /// 才视为相对路径，旧数据的失效绝对路径由 restoreCachedSongs 的
  /// 存在性清洗兑底。
  static Map<String, dynamic> _resolve(
    Map<String, dynamic> json,
    String docs,
  ) {
    for (final k in _pathKeys) {
      final v = json[k];
      if (v is String &&
          v.isNotEmpty &&
          !v.startsWith('/') &&
          !v.contains('://')) {
        json[k] = '$docs/$v';
      }
    }
    return json;
  }
}
