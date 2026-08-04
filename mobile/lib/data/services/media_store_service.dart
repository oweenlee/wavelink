import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../domain/models/song.dart';
import 'media_store_channel.dart';

/// 通过平台系统音乐库（Android MediaStore / iOS MPMediaQuery）扫描音乐
class MediaStoreService {
  static Future<bool> get isAvailable async {
    if (Platform.isIOS) return true;
    try {
      return await MediaStoreChannel.checkPermission();
    } catch (_) {
      return false;
    }
  }

  /// 请求权限（iOS 走原生通道，Android 也走原生通道）
  static Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      return MediaStoreChannel.requestPermission();
    }
    try {
      return await MediaStoreChannel.requestPermission();
    } catch (e) {
      debugPrint('[MediaStore] permission request failed: $e');
      return false;
    }
  }

  /// 扫描系统音乐库
  static Future<List<Song>> scanAll() async {
    if (Platform.isIOS) {
      final hasPerm = await requestPermission();
      if (!hasPerm) return [];
    }

    if (!await isAvailable) return [];

    try {
      return await MediaStoreChannel.scanAll();
    } catch (e) {
      debugPrint('[MediaStore] scan failed: $e');
      return [];
    }
  }

  /// 按专辑分组
  static Future<Map<String, List<Song>>> scanByAlbums() async {
    final songs = await scanAll();
    final grouped = <String, List<Song>>{};
    for (final s in songs) {
      grouped.putIfAbsent(s.album, () => []).add(s);
    }
    return grouped;
  }
}
