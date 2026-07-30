import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';

/// 系统音乐库扫描通道（封装 Android MediaStore / iOS MPMediaQuery 原生调用）
class MediaStoreChannel {
  static const _channel = MethodChannel('wavelink/media_store');

  static bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  /// 检查音乐库权限状态
  static Future<bool> checkPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 请求音乐库权限
  static Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 扫描全部歌曲
  static Future<List<Song>> scanAll() async {
    try {
      final result = await _channel.invokeMethod('scanAll');
      if (result == null) return [];
      return (result as List)
          .map((e) => _toSong(e as Map<String, dynamic>))
          .where((s) => s != null)
          .cast<Song>()
          .toList();
    } catch (e) {
      debugPrint('[MediaStoreChannel] scanAll failed: $e');
      return [];
    }
  }

  static Song? _toSong(Map<String, dynamic> map) {
    final path = map['path'] as String?;
    if (path == null || path.isEmpty) return null;

    return Song(
      id: map['id'] as String,
      title: map['title'] as String? ?? 'Unknown',
      artist: map['artist'] as String? ?? 'Unknown Artist',
      album: map['album'] as String? ?? 'Unknown Album',
      duration: Duration(milliseconds: map['duration'] as int? ?? 0),
      dominantColor: _colorFromPath(path),
      path: path,
      hasCover: true,
    );
  }

  /// 获取封面（Android 走 FFI，该方法仅用于 iOS）
  static Future<Uint8List?> getArtwork(String persistentId) async {
    try {
      final result = await _channel.invokeMethod('getArtwork', {
        'persistentId': persistentId,
      });
      return result as Uint8List?;
    } catch (e) {
      return null;
    }
  }

  /// 从歌曲 id 中提取 iOS persistent ID（格式 ios_{pid}）
  static String? parsePersistentId(String songId) {
    if (!songId.startsWith('ios_')) return null;
    return songId.substring(4);
  }

  static Color _colorFromPath(String path) {
    final hash = path.hashCode;
    final palette = AppTheme.palette;
    return palette[hash.abs() % palette.length];
  }
}
