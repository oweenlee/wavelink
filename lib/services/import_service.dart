import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../services/rust_service.dart' as rs;
import '../services/file_picker_service.dart';

/// 音乐文件导入服务
class ImportService {
  static const _extensions = [
    'mp3', 'flac', 'wav', 'aac', 'ogg', 'm4a',
    'wma', 'alac', 'aiff', 'dsf', 'dff', 'opus',
  ];

  /// 从 app Documents/ 扫描已有音频文件（异步读取元数据）
  static Future<List<Song>> scanDocuments() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = await _listAudioFiles(dir);
    if (files.isEmpty) return [];

    return await _filesToSongs(files);
  }

  static Future<List<File>> _listAudioFiles(Directory dir) async {
    final files = <File>[];
    if (!await dir.exists()) return files;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && _isAudio(entity.path)) {
        files.add(entity);
      }
    }
    return files;
  }

  static bool _isAudio(String path) {
    final ext = path.split('.').last.toLowerCase();
    return _extensions.contains(ext);
  }

  /// 批量将文件转为 Song 对象（优先用 Rust 读取真实元数据）
  static Future<List<Song>> _filesToSongs(List<File> files) async {
    final songs = <Song>[];
    for (final file in files) {
      Song? song;
      // Rust 可用时读取真实元数据
      if (rs.rustAvailable) {
        try {
          final meta = await rs.readMetadata(file.path);
          final title = meta.title ?? _titleFromPath(file.path);
          final artist = meta.artist ?? '未知艺术家';
          final albumName = meta.album ?? '导入的音乐';
          final duration = meta.durationSecs > 0
              ? Duration(milliseconds: (meta.durationSecs * 1000).round())
              : _estimateDuration(file);

          song = Song(
            id: 'imp_${file.path.hashCode}',
            title: title,
            artist: artist,
            album: albumName,
            duration: duration,
            dominantColor: _colorFromPath(file.path),
            path: file.path,
            hasCover: meta.hasCover,
          );
        } catch (_) {
          // Rust 读取失败，降级到文件名猜测
        }
      }

      // 降级：用文件名猜测
      song ??= _fileToSong(file);
      songs.add(song);
    }
    return songs;
  }

  static String _titleFromPath(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  static Duration _estimateDuration(File file) {
    final sizeMb = (file.statSync().size / (1024 * 1024)).clamp(0.1, 9999);
    final estMin = (sizeMb / 1.2).ceil().clamp(1, 999);
    return Duration(minutes: estMin);
  }

  static Color _colorFromPath(String path) {
    final hash = path.hashCode;
    final palette = AppPalette.colors;
    return palette[hash.abs() % palette.length];
  }

  /// 纯文件名猜测降级（不含 Rust 调用）
  static Song _fileToSong(File file) {
    final name = file.path.split('/').last;
    final title = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    return Song(
      id: 'imp_${file.path.hashCode}',
      title: title,
      artist: '未知艺术家',
      album: '导入的音乐',
      duration: _estimateDuration(file),
      dominantColor: _colorFromPath(file.path),
      path: file.path,
    );
  }

  /// 打开文件选择器 → 复制到 Documents/Imported/
  static Future<List<Song>> pickAndImport() async {
    final paths = await FilePickerService.pickFiles();
    if (paths.isEmpty) return [];

    final appDir = await getApplicationDocumentsDirectory();
    final importDir = Directory('${appDir.path}/Imported');
    if (!await importDir.exists()) await importDir.create(recursive: true);

    final files = <File>[];
    for (final srcPath in paths) {
      final name = srcPath.split('/').last;
      final dest = File('${importDir.path}/$name');
      if (!await dest.exists()) {
        await File(srcPath).copy(dest.path);
      }
      files.add(dest);
    }
    return await _filesToSongs(files);
  }
}

/// 颜色调色板（20 种现代配色）
class AppPalette {
  static const colors = [
    Color(0xFF6C5CE7), // 紫
    Color(0xFF00B894), // 翡翠
    Color(0xFFFD79A8), // 粉
    Color(0xFF0984E3), // 蓝
    Color(0xFFE17055), // 陶土
    Color(0xFF00CEC9), // 青
    Color(0xFFFDCB6E), // 金
    Color(0xFFA29BFE), // 淡紫
    Color(0xFF55EFC4), // 薄荷
    Color(0xFFFAB1A0), // 淡粉
    Color(0xFF74B9FF), // 天蓝
    Color(0xFFDFE6E9), // 银灰
    Color(0xFFE84393), // 品红
    Color(0xFF00B894), // 翠绿
    Color(0xFF6C5CE7), // 紫罗兰
    Color(0xFFFDCB6E), // 琥珀
    Color(0xFFE17055), // 珊瑚
    Color(0xFF00CEC9), // 蓝绿
    Color(0xFFFD79A8), // 玫瑰
    Color(0xFF0984E3), // 钴蓝
  ];
}
