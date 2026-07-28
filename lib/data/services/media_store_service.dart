import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';
import 'media_store_channel.dart';

/// 通过平台系统音乐库（Android MediaStore / iOS MPMediaQuery）扫描音乐
class MediaStoreService {
  static final _audioQuery = OnAudioQuery();

  static Future<bool> get isAvailable async {
    if (Platform.isIOS) return true;
    try {
      final status = await _audioQuery.permissionsStatus();
      return status;
    } catch (_) {
      return false;
    }
  }

  /// 请求权限
  static Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      return MediaStoreIOSChannel.requestPermission();
    }
    try {
      final status = await _audioQuery.permissionsRequest();
      return status;
    } catch (e) {
      debugPrint('[MediaStore] permission request failed: $e');
      return false;
    }
  }

  /// 扫描系统音乐库
  static Future<List<Song>> scanAll({
    SongSortType sortType = SongSortType.DATE_ADDED,
    OrderType orderType = OrderType.DESC_OR_GREATER,
    UriType uriType = UriType.EXTERNAL,
  }) async {
    if (Platform.isIOS) {
      final hasPerm = await requestPermission();
      if (!hasPerm) return [];
      return MediaStoreIOSChannel.scanAll();
    }

    if (!await isAvailable) return [];

    try {
      final raw = await _audioQuery.querySongs(
        sortType: sortType,
        orderType: orderType,
        uriType: uriType,
        ignoreCase: true,
      );
      return raw.map(_toSong).where((s) => s != null).cast<Song>().toList();
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

  /// 获取封面字节
  static Future<Uint8List?> getArtwork(int? albumId, String? uri) async {
    try {
      if (albumId != null) {
        return await _audioQuery.queryArtwork(
          albumId,
          ArtworkType.ALBUM,
          size: 512,
        );
      }
      if (uri != null) {
        return await _audioQuery.queryArtwork(
          uri.hashCode,
          ArtworkType.AUDIO,
          size: 512,
        );
      }
    } catch (_) {}
    return null;
  }

  static Song? _toSong(SongModel m) {
    final path = m.data;
    if (path.isEmpty) return null;

    final file = File(path);
    if (!file.existsSync()) return null;

    return Song(
      id: 'ms_${m.id}',
      title: m.title.isNotEmpty ? m.title : _titleFromPath(path),
      artist: (m.artist != null && m.artist!.isNotEmpty)
          ? m.artist!
          : 'Unknown Artist',
      album: (m.album != null && m.album!.isNotEmpty)
          ? m.album!
          : 'Unknown Album',
      duration: Duration(milliseconds: m.duration ?? 0),
      dominantColor: _colorFromPath(path),
      path: path,
      hasCover: true,
    );
  }

  static String _titleFromPath(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  static Color _colorFromPath(String path) {
    final hash = path.hashCode;
    final palette = AppTheme.palette;
    return palette[hash.abs() % palette.length];
  }
}
