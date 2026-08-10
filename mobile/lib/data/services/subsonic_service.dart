import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';
import 'preferences_service.dart';
import 'log.dart';

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

  /// 从持久化配置恢复（app 启动时调用）
  static void loadFromPrefs() {
    final prefs = PreferencesService.instance;
    final url = prefs.subsonicBaseUrl;
    final user = prefs.subsonicUsername;
    if (url != null && url.isNotEmpty && user != null && user.isNotEmpty) {
      configure(baseUrl: url, username: user, password: prefs.subsonicPassword);
    }
  }

  /// 连接测试：ping 服务器并校验凭据，成功返回 true
  static Future<bool> testConnection({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    try {
      final url = baseUrl.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$url/rest/ping').replace(queryParameters: {
        'u': username,
        'p': password,
        'v': '1.16.0',
        'c': 'wavelink',
      });
      final resp = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;
      final json = jsonDecode(resp.body);
      final status = json['subsonic-response']?['status'] as String?;
      return status == 'ok';
    } catch (e) {
      Log.e('Subsonic', 'ping failed: $e');
      return false;
    }
  }

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
      // getAlbumList2（标准端点，type=alphabeticalByName）：分页拉全量专辑，
      // 每张专辑再 getAlbum 拿歌曲。注意 getArtists 的 artist 在 index[] 分组里、
      // getAlbums 非标准端点，均不可用。
      var offset = 0;
      const pageSize = 500;
      while (true) {
        final albumListResp = await _get('/getAlbumList2', {
          'type': 'alphabeticalByName',
          'size': '$pageSize',
          'offset': '$offset',
        });
        if (albumListResp.statusCode != 200) break;

        final albumListJson = jsonDecode(albumListResp.body);
        final albums =
            albumListJson['subsonic-response']?['albumList2']?['album']
                as List?;
        if (albums == null || albums.isEmpty) break;

        for (final album in albums) {
          final albumId = album['id'] as String?;
          if (albumId == null) continue;
          final albumName = album['name'] as String?;
          final albumArtist = album['artist'] as String?;

          final songResponse = await _get('/getAlbum', {'id': albumId});
          if (songResponse.statusCode != 200) continue;

          final songJson = jsonDecode(songResponse.body);
          final tracks =
              songJson['subsonic-response']?['album']?['song'] as List?;
          if (tracks == null) continue;

          for (final track in tracks) {
            final song = _toSong(track, albumArtist, albumName);
            if (song != null) songs.add(song);
          }
        }

        if (albums.length < pageSize) break;
        offset += pageSize;
      }
    } catch (e) {
      Log.e('Subsonic', 'scanLibrary failed: $e');
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

      return result
          .map((t) {
            final artist = t['artist'] as String?;
            final album = t['album'] as String?;
            return _toSong(t, artist, album);
          })
          .whereType<Song>()
          .toList();
    } catch (e) {
      Log.e('Subsonic', 'searchSongs failed: $e');
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
    String? streamUrl;
    if (_baseUrl != null) {
      if (coverArt != null) {
        coverUrl =
            '$_baseUrl/rest/getCoverArt?id=$coverArt&u=$_username&p=$_password&v=1.16.0&c=wavelink';
      }
      if (songId != null) {
        streamUrl =
            '$_baseUrl/rest/stream?id=$songId&u=$_username&p=$_password&v=1.16.0&c=wavelink';
      }
    }

    return Song(
      id: 'sub_${songId ?? path.hashCode}',
      title: title.isNotEmpty ? title : _titleFromPath(path ?? songId ?? ''),
      artist: artist,
      album: albumName,
      duration: Duration(milliseconds: durationMs),
      dominantColor: _colorFromPath(path ?? songId ?? ''),
      path: path,
      streamUrl: streamUrl,
      coverUrl: coverUrl,
      hasCover: coverUrl != null,
    );
  }

  static String _titleFromPath(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  static Color _colorFromPath(String path) {
    return AppTheme.s2;
  }
}
