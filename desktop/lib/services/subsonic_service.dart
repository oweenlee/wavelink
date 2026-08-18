import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'network_source_config.dart';
import 'scan_helpers.dart';

/// Subsonic / Navidrome / Jellyfin / Emby API 客户端（桌面端）。
///
/// 通过 HTTP(S) 访问 NAS 上的音乐服务器（兼容 Subsonic API / OpenSubsonic）。
/// 扫描（[scanLibrary]）按专辑分页拉全量曲目建索引，返回 [Track]
/// （[TrackSource.subsonic]，[streamUrl] 为完整流地址，[coverUrl] 为远程封面）。
///
/// 播放策略：下载 [streamUrl] 到本地缓存后由引擎本地播放
/// （Subsonic 标准流端点为整曲下载，无核心层流式解码，与 mobile 一致）。
class SubsonicService {
  SubsonicService._();

  static String? _baseUrl;
  static String? _username;
  static String? _password;

  static bool get isConfigured =>
      _baseUrl != null &&
      _baseUrl!.isNotEmpty &&
      _username != null &&
      _username!.isNotEmpty;

  /// 从持久化配置恢复（app 启动时调用）。
  static void loadFromPrefs() {
    final cfg = NetworkSourceConfig.instance;
    final url = cfg.subsonicBaseUrl;
    final user = cfg.subsonicUsername;
    if (url != null && url.isNotEmpty && user != null && user.isNotEmpty) {
      configure(
        baseUrl: url,
        username: user,
        password: cfg.subsonicPassword,
      );
    }
  }

  /// 连接测试：ping 服务器并校验凭据，成功返回 null，否则错误信息。
  static Future<String?> testConnection({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    try {
      final url = baseUrl.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$url/rest/ping').replace(
        queryParameters: {
          'u': username,
          'p': password,
          'v': '1.16.0',
          'c': 'wavelink',
        },
      );
      final resp = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return 'HTTP ${resp.statusCode}';
      final json = jsonDecode(resp.body);
      final status = json['subsonic-response']?['status'] as String?;
      return status == 'ok' ? null : '凭据校验失败（status=$status）';
    } catch (e) {
      return '连接失败：$e';
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
    return await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
  }

  static Map<String, dynamic> _parse(http.Response resp, String what) {
    if (resp.statusCode != 200) {
      throw HttpException('$what 返回 ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body);
    final sub = json is Map ? json['subsonic-response'] : null;
    if (sub is Map && sub['status'] == 'failed') {
      final err = sub['error'];
      final msg = err is Map ? err['message'] : null;
      throw HttpException('$what 服务端错误${msg != null ? '：$msg' : ''}');
    }
    return json as Map<String, dynamic>;
  }

  /// 分页拉全量专辑 → 每专辑 getAlbum 拿歌曲。
  /// 失败抛异常（交由调用方处理/回显），不静默返回空。
  static Future<List<Track>> scanLibrary() async {
    if (!isConfigured) return [];

    final tracks = <Track>[];
    var offset = 0;
    const pageSize = 500;
    while (true) {
      final albumListResp = await _get('/getAlbumList2', {
        'type': 'alphabeticalByName',
        'size': '$pageSize',
        'offset': '$offset',
      });
      final albumListJson = _parse(albumListResp, 'getAlbumList2');
      final albums =
          albumListJson['subsonic-response']?['albumList2']?['album'] as List?;
      if (albums == null || albums.isEmpty) break;

      for (final album in albums.cast<Map<String, dynamic>>()) {
        final albumId = album['id'] as String?;
        if (albumId == null) continue;
        final albumName = album['name'] as String?;
        final albumArtist = album['artist'] as String?;

        final songResponse = await _get('/getAlbum', {'id': albumId});
        final songJson = _parse(songResponse, 'getAlbum($albumId)');
        final songs =
            songJson['subsonic-response']?['album']?['song'] as List?;
        if (songs == null) continue;

        for (final song in songs.cast<Map<String, dynamic>>()) {
          final track = _toTrack(song, albumArtist, albumName);
          if (track != null) tracks.add(track);
        }
      }

      if (albums.length < pageSize) break;
      offset += pageSize;
    }
    return tracks;
  }

  static Track? _toTrack(
    Map<String, dynamic> t,
    String? fallbackArtist,
    String? fallbackAlbum,
  ) {
    final title = t['title'] as String? ?? '';
    final artist =
        (t['artist'] as String?) ?? fallbackArtist ?? 'Unknown Artist';
    final albumName = (t['album'] as String?) ?? fallbackAlbum ?? 'Unknown Album';
    final path = t['path'] as String?;
    final durationMs = (t['duration'] as num?)?.toInt() ?? 0;
    final coverArt = t['coverArt'] as String?;
    final songId = t['id'] as String?;
    if (songId == null) return null;

    String? coverUrl;
    String? streamUrl;
    if (_baseUrl != null) {
      if (coverArt != null) {
        coverUrl = '$_baseUrl/rest/getCoverArt?id=$coverArt'
            '&u=$_username&p=$_password&v=1.16.0&c=wavelink';
      }
      final q = _authParams();
      final uri = Uri.parse('$_baseUrl/rest/stream').replace(
        queryParameters: {'id': songId, ...q},
      );
      streamUrl = uri.toString();
    }

    return Track(
      id: 'sub_$songId',
      title: title.isNotEmpty ? title : _titleFromPath(path ?? songId),
      artist: artist,
      album: albumName,
      source: TrackSource.subsonic,
      remotePath: path,
      streamUrl: streamUrl,
      coverUrl: coverUrl,
      durationHint: Duration(milliseconds: durationMs),
      durationEstimated: false,
    );
  }

  static String _titleFromPath(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  // ── 下载缓存（播放用） ──

  /// 下载 [track] 的流到本地缓存并返回路径；已缓存则直接命中。
  /// Subsonic 无核心层流式解码，必须整曲下载后本地播放。
  static Future<String?> downloadStream(
    Track track, {
    void Function(int count, int total)? onProgress,
  }) async {
    if (track.streamUrl == null) return null;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.subsonic_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final ext = _extFromUrl(track.streamUrl!);
      final localFile = File('${cacheDir.path}/${track.id.hashCode}$ext');
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      final tmp = File('${localFile.path}.part');
      final resp = await http
          .get(Uri.parse(track.streamUrl!))
          .timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) return null;
      await tmp.writeAsBytes(resp.bodyBytes, flush: true);
      if (await tmp.length() == 0) {
        await tmp.delete();
        return null;
      }
      await tmp.rename(localFile.path);
      return localFile.path;
    } catch (e) {
      return null;
    }
  }

  static String _extFromUrl(String url) {
    final path = Uri.parse(url).path;
    final ext = path.split('.').last.toLowerCase();
    return audioExtensions.contains('.$ext') ? '.$ext' : '.mp3';
  }
}
