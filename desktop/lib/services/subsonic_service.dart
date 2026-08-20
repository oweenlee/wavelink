import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'network_source_config.dart';
import 'scan_helpers.dart';
import 'stable_hash.dart';

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

  /// 最近一次扫描/操作的用户可读错误（供 UI 在扫描结果为空时提示原因）。
  static String? lastError;

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
      // token 认证：t=当前 epoch 秒，s=md5(密码+t)，避免明文密码进 URL
      final t = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final s = md5.convert(utf8.encode('$password$t')).toString();
      final uri = Uri.parse('$url/rest/ping').replace(
        queryParameters: {
          'u': username,
          't': t,
          's': s,
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

  /// Subsonic token 认证参数（OpenSubsonic）：`t` 为当前时间戳（epoch 秒），
  /// `s` 为 `md5(密码 + t)`。避免把明文密码拼进 URL query（会进日志/历史）。
  static Map<String, String> _authParams() {
    final t = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final s = md5.convert(utf8.encode('$_password$t')).toString();
    return {
      'u': _username!,
      't': t,
      's': s,
      'v': '1.16.0',
      'c': 'wavelink',
    };
  }

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
    lastError = null;

    final tracks = <Track>[];
    try {
      var offset = 0;
      const pageSize = 500;
      while (true) {
        final albumListResp = await _get('/getAlbumList2', {
          'type': 'alphabeticalByName',
          'size': '$pageSize',
          'offset': '$offset',
        });
        final albumListJson = _parse(albumListResp, 'getAlbumList2');
        final albums = albumListJson['subsonic-response']?['albumList2']?['album']
            as List?;
        if (albums == null || albums.isEmpty) break;

        // 每专辑 getAlbum 拿歌曲：全串行在大库下是 N+1 慢路径（500 专辑 ×
        // 单请求耗时），用有界并发（4）并行拉取提速，同时避免压垮服务器。
        final albumTracks = await _mapConcurrent<Map<String, dynamic>, List<Track>>(
          albums.cast<Map<String, dynamic>>().toList(),
          concurrency: 4,
          fn: (album) async {
            final albumId = album['id'] as String?;
            if (albumId == null) return <Track>[];
            final albumName = album['name'] as String?;
            final albumArtist = album['artist'] as String?;

            final songResponse = await _get('/getAlbum', {'id': albumId});
            final songJson = _parse(songResponse, 'getAlbum($albumId)');
            final songs =
                songJson['subsonic-response']?['album']?['song'] as List?;
            if (songs == null) return <Track>[];

            return songs
                .cast<Map<String, dynamic>>()
                .map((song) => _toTrack(song, albumArtist, albumName))
                .whereType<Track>()
                .toList();
          },
        );
        for (final list in albumTracks) {
          tracks.addAll(list);
        }

        if (albums.length < pageSize) break;
        offset += pageSize;
      }
    } catch (e) {
      lastError = 'Subsonic 扫描失败：$e';
      rethrow;
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
        // 用 token 参数拼 query，避免明文密码进 URL
        final q = _authParams();
        coverUrl = Uri.parse('$_baseUrl/rest/getCoverArt').replace(
          queryParameters: {'id': coverArt, ...q},
        ).toString();
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
    // 播放时用最新时间戳重新生成鉴权参数：扫描期烤进 Track.streamUrl 的
    // token（t 为 epoch 秒）对严格服务器会过期，数小时后取流 401。
    final url = streamUrlFor(track);
    if (url == null) return null;
    File? tmp;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.subsonic_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final ext = _extFromUrl(url);
      final localFile =
          File('${cacheDir.path}/${fnv1a(track.id)}$ext');
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      tmp = File('${localFile.path}.part');
      // 流式写入：避免整曲读进内存再落盘（大文件内存尖峰）。
      // webdav 已是流式，subsonic 此前用 bodyBytes 整首进内存，行为不一致。
      // 流式需走 Client.send 拿 StreamedResponse（http.get 的 Response 是整读）。
      final client = http.Client();
      try {
        final resp = await client
            .send(http.Request('GET', Uri.parse(url)))
            .timeout(const Duration(minutes: 5));
        if (resp.statusCode != 200) return null;
        // body 读取也包超时：5min 只盖住 TTFB，服务端发完 header 后不再吐
        // 数据仍会无限挂起。单块 2min 无数据即判死（正常传输块间隔远小于此）。
        await resp.stream
            .timeout(const Duration(minutes: 2))
            .pipe(tmp.openWrite());
      } finally {
        client.close();
      }
      if (await tmp.length() == 0) {
        await tmp.delete();
        return null;
      }
      await tmp.rename(localFile.path);
      return localFile.path;
    } catch (e) {
      // 失败清理半截 .part，避免残留中间文件。
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
      return null;
    }
  }

  /// 刷新 Subsonic URL 的鉴权参数（u/t/s/v/c），保留资源 id 等原有 query。
  ///
  /// `_authParams()` 的 `t` 是当前 epoch 秒、`s` = md5(密码 + t)，两者自洽
  /// （标准服务器不校验时间窗），但**部分严格服务器**按 `t` 时间戳拒绝过期
  /// token。扫描期烤进 Track 的 URL 数小时后即过期，故播放/取封面时按最新
  /// 时间戳重新生成 t/s（对任意服务器都安全），资源 id（歌曲/封面）不变。
  static String? _refreshAuth(String? url) {
    if (url == null || _baseUrl == null) return url;
    final uri = Uri.parse(url);
    final params = <String, String>{...uri.queryParameters};
    params.removeWhere((k, _) => const ['u', 't', 's', 'v', 'c'].contains(k));
    params.addAll(_authParams());
    return uri.replace(queryParameters: params).toString();
  }

  /// 带新鲜鉴权的流地址（播放下载用）。
  static String? streamUrlFor(Track track) => _refreshAuth(track.streamUrl);

  /// 带新鲜鉴权的封面地址（封面提取/显示用）。
  static String? coverUrlFor(Track track) => _refreshAuth(track.coverUrl);

  static String _extFromUrl(String url) {
    final path = Uri.parse(url).path;
    final ext = path.split('.').last.toLowerCase();
    return audioExtensions.contains('.$ext') ? '.$ext' : '.mp3';
  }

  /// 有界并发 map：同时最多 [concurrency] 个任务，保持结果按输入顺序。
  static Future<List<R>> _mapConcurrent<T, R>(
    List<T> items, {
    required int concurrency,
    required Future<R> Function(T item) fn,
  }) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= items.length) return;
        results[i] = await fn(items[i]);
      }
    }

    final n = concurrency.clamp(1, items.isEmpty ? 1 : items.length);
    await Future.wait(List.generate(n, (_) => worker()));
    return results.whereType<R>().toList();
  }
}
