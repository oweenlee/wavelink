import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/song.dart';

/// 曲库列表的轻量持久化：整表 JSON 存 Documents/.library_cache.json
///
/// 歌曲列表变化（导入/扫描）时 fire-and-forget 写盘，
/// App 启动时读回恢复曲库，避免重启后一片空白。
class LibraryCacheService {
  LibraryCacheService._();

  static const _fileName = '.library_cache.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// 写盘（失败静默，不影响主流程）
  static Future<void> saveSongs(List<Song> songs) async {
    try {
      final file = await _file();
      final data = jsonEncode(songs.map((s) => s.toJson()).toList());
      await file.writeAsString(data);
    } catch (e) {
      debugPrint('[LibraryCache] 保存失败: $e');
    }
  }

  /// 读回；文件不存在/损坏均返回空列表
  static Future<List<Song>> loadSongs() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final data = await file.readAsString();
      if (data.isEmpty) return [];
      final list = jsonDecode(data) as List<dynamic>;
      return list
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[LibraryCache] 读取失败: $e');
      return [];
    }
  }
}
