import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as wd;

import '../models/track.dart';
import '../src/rust/api/webdav.dart' as frb_webdav;
import 'network_source_config.dart';
import 'scan_helpers.dart';

/// WebDAV 音乐服务器服务（桌面端）。
///
/// 基于 [wd.Client]（basic/digest/匿名自动协商）访问远程 WebDAV 目录，
/// 递归扫描音频建索引，返回 [Track]（[TrackSource.webdav]）。
/// 播放策略由 PlayerController 决定：优先 Rust 边下边播
/// （[frb_webdav.enginePlayWebdavStream]），失败回退本服务的
/// [downloadToLocal] 全量缓存。
///
/// 配置复用 [NetworkSourceConfig] 的 webdav* 字段。
class WebdavService {
  WebdavService._();

  /// 懒创建并复用的 WebDAV client（按 baseUrl|user|pass 指纹缓存）。
  static wd.Client? _client;
  static String? _clientKey;

  /// 扫描进行中标记：期间禁止重复扫描（与 mobile 一致）。
  static bool _scanning = false;

  /// 进行中的下载（按 davPath 去重），并发调用共享同一次下载。
  static final Map<String, Future<String?>> _downloading = {};

  /// 最近一次操作的具体错误（UI 排查用）。
  static String? lastError;

  static const _albumPlaceholder = 'WebDAV Music';
  static const _artistPlaceholder = 'Unknown Artist';

  static String? get baseUrl => NetworkSourceConfig.instance.webdavBaseUrl;
  static String? get rootPath => NetworkSourceConfig.instance.webdavPath;
  static String get username =>
      NetworkSourceConfig.instance.webdavUsername ?? '';
  static String get password => NetworkSourceConfig.instance.webdavPassword;

  static bool get isConfigured {
    final b = baseUrl;
    return b != null && b.isNotEmpty;
  }

  /// 拼接远端完整 URL（baseUrl + davPath），斜杠规范化；
  /// davPath 若已是完整 URL 则原样返回。
  static String? fullUrlFor(String davPath) {
    final base = baseUrl;
    if (base == null || base.isEmpty) return null;
    if (davPath.startsWith('http://') || davPath.startsWith('https://')) {
      return davPath;
    }
    final l = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final r = davPath.startsWith('/') ? davPath.substring(1) : davPath;
    return '$l/$r';
  }

  /// 读取远端小文件全文（歌词等），失败/不存在返回 null。
  static Future<Uint8List?> readRemoteBytes(String davPath) async {
    try {
      final base = baseUrl;
      if (base == null || base.isEmpty) return null;
      final client = _buildClient(base, username, password);
      if (client == null) return null;
      final bytes = await client.read(davPath).timeout(const Duration(seconds: 30));
      return bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } catch (_) {
      // 文件不存在或读取失败（歌词为可选项，静默降级）
      return null;
    }
  }

  static wd.Client? _buildClient(String base, String user, String pass) {
    final key = '$base|$user|$pass';
    if (_client == null || _clientKey != key) {
      _client = wd.newClient(base, user: user, password: pass);
      _client!.setConnectTimeout(10000);
      _client!.setReceiveTimeout(30000);
      _clientKey = key;
    }
    return _client;
  }

  /// 连接测试：用显式参数（未保存的临时配置）。
  /// 返回 null 表示成功，否则返回错误信息。
  static Future<String?> testConnection({
    required String baseUrl,
    String path = '',
    String username = '',
    String password = '',
  }) async {
    try {
      final client = wd.newClient(baseUrl, user: username, password: password);
      client.setConnectTimeout(10000);
      client.setReceiveTimeout(30000);
      await client.ping().timeout(const Duration(seconds: 15));
      await client.readDir(path).timeout(const Duration(seconds: 15));
      return null;
    } catch (e) {
      lastError = '$e';
      return lastError;
    }
  }

  /// 递归扫描音频文件，按 [onBatch] 增量回调（每 20 首一批）。
  /// 返回全量结果（调用方据此 prune 旧索引）。
  static Future<List<Track>> scanWebdav({
    void Function(List<Track> batch)? onBatch,
  }) async {
    if (_scanning) return const [];
    _scanning = true;
    lastError = null;
    final root = rootPath ?? '';
    List<Track> tracks;
    try {
      final client = _buildClient(
        baseUrl!,
        NetworkSourceConfig.instance.webdavUsername ?? '',
        NetworkSourceConfig.instance.webdavPassword,
      );
      if (client == null) {
        tracks = const [];
      } else {
        List<wd.File> rootEntries;
        try {
          rootEntries =
              await client.readDir(root).timeout(const Duration(seconds: 30));
        } catch (e) {
          lastError = '$e';
          tracks = const [];
          rootEntries = const [];
        }
        if (lastError == null) {
          tracks = await _scanEntries(client, rootEntries, root);
        } else {
          tracks = const [];
        }
      }
    } catch (e) {
      lastError = '$e';
      tracks = const [];
    } finally {
      _scanning = false;
    }
    if (onBatch != null && tracks.isNotEmpty) {
      for (var i = 0; i < tracks.length; i += 20) {
        final end = (i + 20).clamp(0, tracks.length);
        onBatch(tracks.sublist(i, end));
      }
    }
    return tracks;
  }

  /// 处理单个目录条目：音频直接建 [Track]，子目录并发递归。
  /// 同层子目录用 [Future.wait] 并发列举（HTTP 客户端串行度由服务端/连接池限制）。
  static Future<List<Track>> _scanEntries(
    wd.Client client,
    List<wd.File> entries,
    String path,
  ) async {
    final dirs = <String>[];
    final tracks = <Track>[];
    for (final entry in entries) {
      final entryPath = entry.path;
      if (entryPath == null || entryPath.isEmpty) continue;
      if (entry.isDir == true) {
        dirs.add(entryPath);
      } else {
        final track = _toTrack(entry);
        if (track != null) tracks.add(track);
      }
    }
    if (dirs.isNotEmpty) {
      final subs = await Future.wait(dirs.map((d) => _scanSubtree(client, d)));
      for (final r in subs) tracks.addAll(r);
    }
    return tracks;
  }

  /// 递归扫描单个子目录；列举失败隔离跳过（返回空），不影响其余目录。
  static Future<List<Track>> _scanSubtree(wd.Client client, String path) async {
    List<wd.File> entries;
    try {
      entries = await client.readDir(path).timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('[WebdavService] 子目录列举失败(隔离跳过): $path -> $e');
      return const [];
    }
    return _scanEntries(client, entries, path);
  }

  static Track? _toTrack(wd.File entry) {
    final name = entry.name ?? '';
    final path = entry.path ?? '';
    if (name.isEmpty || path.isEmpty) return null;
    final ext = name.split('.').last.toLowerCase();
    if (!audioExtensions.contains('.$ext')) return null;

    final (artist, title) = parseArtistTitle(name);
    return Track(
      id: 'dav_${path.hashCode}',
      title: title,
      artist: artist == 'Unknown Artist' ? _artistPlaceholder : artist,
      album: _albumPlaceholder,
      source: TrackSource.webdav,
      remotePath: path,
      durationHint: estimateDuration(entry.size?.toInt() ?? 0),
      durationEstimated: true,
      fileSize: entry.size?.toInt(),
    );
  }

  // ── 下载缓存（边下边播失败时的回退；亦可用于离线） ──

  static Future<String?> _cacheTargetFor(String davPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.webdav_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = davPath.split('/').last;
      return '${cacheDir.path}/${davPath.hashCode}_$name';
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 公开缓存目标路径（供播放分发复用，使边下边播与回退下载命中同一缓存）。
  static Future<String?> cachePathFor(String davPath) =>
      _cacheTargetFor(davPath);

  /// 检查单曲本地缓存是否已就绪（存在且非空才命中）。
  static Future<String?> cachedLocalPath(String davPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.webdav_cache');
      if (!await cacheDir.exists()) return null;
      final name = davPath.split('/').last;
      final localFile = File('${cacheDir.path}/${davPath.hashCode}_$name');
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      return null;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 下载单曲到本地缓存并返回可播放路径；失败返回 null。
  /// 并发调用按 davPath 去重，共享同一次下载。
  static Future<String?> downloadToLocal(
    String davPath, {
    void Function(int count, int total)? onProgress,
  }) async {
    final existing = _downloading[davPath];
    if (existing != null) return existing;
    final future = _downloadToLocalImpl(davPath, onProgress);
    _downloading[davPath] = future;
    try {
      return await future;
    } finally {
      _downloading.remove(davPath);
    }
  }

  static const _parallelChunks = 4;

  static Future<String?> _downloadToLocalImpl(
    String davPath,
    void Function(int count, int total)? onProgress,
  ) async {
    try {
      final target = await _cacheTargetFor(davPath);
      if (target == null) return null;
      final localFile = File(target);
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      final tmpFile = File('${localFile.path}.part');
      if (!await _downloadParallel(davPath, tmpFile, onProgress)) {
        final client = _buildClient(
          baseUrl!,
          NetworkSourceConfig.instance.webdavUsername ?? '',
          NetworkSourceConfig.instance.webdavPassword,
        );
        if (client == null) return null;
        try {
          await client
              .read2File(davPath, tmpFile.path, onProgress: onProgress)
              .timeout(const Duration(minutes: 5));
        } catch (e) {
          lastError = '$e';
          if (await tmpFile.exists()) await tmpFile.delete();
          return null;
        }
      }
      if (!await tmpFile.exists() || await tmpFile.length() == 0) {
        if (await tmpFile.exists()) await tmpFile.delete();
        return null;
      }
      await tmpFile.rename(localFile.path);
      return localFile.path;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 并发分片下载：先探远端大小，按片均分，每片发独立 Range 请求写
  /// `.part.N`，最后按序拼接。服务器不支持 Range / 大小未知 / 任一片失败
  /// 返回 false 回退顺序下载。
  static Future<bool> _downloadParallel(
    String davPath,
    File tmpFile,
    void Function(int count, int total)? onProgress,
  ) async {
    final url = fullUrlFor(davPath);
    if (url == null) return false;
    final partFiles = <File>[];
    try {
      final total = await frb_webdav.engineWebdavFileSize(
        url: url,
        username: username,
        password: password,
      );
      if (total <= BigInt.zero) return false;
      final size = total.toInt();
      final chunkSize = (size + _parallelChunks - 1) ~/ _parallelChunks;
      await Future.wait([
        for (var i = 0; i < _parallelChunks; i++)
          () async {
            final start = i * chunkSize;
            if (start >= size) return;
            final len = math.min(chunkSize, size - start);
            final data = await frb_webdav.engineWebdavDownloadRange(
              url: url,
              username: username,
              password: password,
              offset: BigInt.from(start),
              maxLen: BigInt.from(len),
            );
            if (data.isEmpty) throw StateError('分片 $i 读取为空');
            final part = File('${tmpFile.path}.$i');
            await part.writeAsBytes(data, flush: true);
            partFiles.add(part);
          }(),
      ]);
      final sink = tmpFile.openWrite();
      try {
        var written = 0;
        for (final part in partFiles) {
          await sink.addStream(part.openRead());
          written += await part.length();
          onProgress?.call(written, size);
        }
      } finally {
        await sink.close();
      }
      return true;
    } catch (e) {
      lastError = '$e';
      return false;
    } finally {
      for (final part in partFiles) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }
}
