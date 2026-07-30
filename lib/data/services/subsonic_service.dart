import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';

/// Subsonic / Navidrome / Jellyfin / Emby API 客户端
///
/// 支持通过 HTTP(S) 访问运行在 NAS 上的音乐服务器，
/// 协议兼容 Subsonic API（OpenSubsonic 扩展）。
class SubsonicService {
  SubsonicService._();

  static String? _baseUrl;
  static String? _username;
  static String? _password;

  static bool get isConfigured =>
      _baseUrl != null &&
      _baseUrl!.isNotEmpty &&
      _username != null &&
      _password != null;

  static void configure({
    required String baseUrl,
    required String username,
    required String password,
  }) {
    _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');
    _username = username;
    _password = password;
  }

  static void clear() {
    _baseUrl = null;
    _username = null;
    _password = null;
  }

  static String _url(String path) => '$_baseUrl/rest$path';

  static Map<String, String> _authParams() => {
        'u': _username!,
        'p': _password!,
        'v': '1.16.0',
        'c': 'wavelink',
      };

  static Future<http.Response> _get(
    String path, [
    Map<String, String>? extraParams,
  ]) async {
    final params = Map<String, String>.from(_authParams());
    if (extraParams != null) params.addAll(extraParams);
    final uri = Uri.parse(_url(path)).replace(queryParameters: params);
    return await http.get(uri, headers: {'Accept': 'application/json'});
  }

  static Future<List<Song>> scanLibrary() async {
    if (!isConfigured) return [];

    final songs = <Song>[];

    try {
      final artistResponse = await _get('/getArtists');
      if (artistResponse.statusCode != 200) return [];

      final artistsJson = jsonDecode(artistResponse.body);
      final artists =
          artistsJson['subsonic-response']?['artists']?['artist'] as List?;
      if (artists == null) return [];

      for (final artist in artists) {
        final artistId = artist['id'] as String?;
        if (artistId == null) continue;

        final albumResponse = await _get('/getAlbums', {'artistId': artistId});
        if (albumResponse.statusCode != 200) continue;

        final albumsJson = jsonDecode(albumResponse.body);
        final albums =
            albumsJson['subsonic-response']?['albums']?['album'] as List?;
        if (albums == null) continue;

        for (final album in albums) {
          final albumId = album['id'] as String?;
          if (albumId == null) continue;

          final songResponse = await _get('/getAlbum', {'id': albumId});
          if (songResponse.statusCode != 200) continue;

          final songJson = jsonDecode(songResponse.body);
          final tracks =
              songJson['subsonic-response']?['album']?['song'] as List?;
          if (tracks == null) continue;

          for (final track in tracks) {
            final song = _toSong(
              track,
              artist['name'] as String?,
              album['name'] as String?,
            );
            if (song != null) songs.add(song);
          }
        }
      }
    } catch (e) {
      debugPrint('[Subsonic] scanLibrary failed: $e');
      return [];
    }

    return songs;
  }

  static Future<List<Song>> searchSongs(String query) async {
    if (!isConfigured) return [];

    try {
      final response = await _get('/search3', {
        'query': query,
        'pageSize': '50',
      });
      if (response.statusCode != 200) return [];

      final json = jsonDecode(response.body);
      final result =
          json['subsonic-response']?['searchResult3']?['song'] as List?;
      if (result == null) return [];

      return result.map((t) {
        final artist = t['artist'] as String?;
        final album = t['album'] as String?;
        return _toSong(t, artist, album);
      }).whereType<Song>().toList();
    } catch (e) {
      debugPrint('[Subsonic] searchSongs failed: $e');
      return [];
    }
  }

  static Song? _toSong(
    Map<String, dynamic> track,
    String? fallbackArtist,
    String? fallbackAlbum,
  ) {
    final title = track['title'] as String? ?? '';
    final artist =
        (track['artist'] as String?) ?? fallbackArtist ?? 'Unknown Artist';
    final albumName =
        (track['album'] as String?) ?? fallbackAlbum ?? 'Unknown Album';
    final path = track['path'] as String?;
    final durationMs = (track['duration'] as num?)?.toInt() ?? 0;
    final coverArt = track['coverArt'] as String?;
    final songId = track['id'] as String?;

    if (path == null && songId == null) return null;

    String? coverUrl;
    if (coverArt != null && _baseUrl != null) {
      coverUrl =
          '$_baseUrl/rest/getCoverArt?id=$coverArt&u=$_username&p=$_password&v=1.16.0&c=wavelink';
    }

    return Song(
      id: 'sub_${songId ?? path.hashCode}',
      title: title.isNotEmpty
          ? title
          : _titleFromPath(path ?? songId ?? ''),
      artist: artist,
      album: albumName,
      duration: Duration(milliseconds: durationMs),
      dominantColor: _colorFromPath(path ?? songId ?? ''),
      path: path,
      coverUrl: coverUrl,
      hasCover: coverUrl != null,
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