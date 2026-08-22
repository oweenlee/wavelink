import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as wd;

import '../models/track.dart';
import '../src/rust/api/webdav.dart' as frb_webdav;
import '../src/rust/api/duration.dart' as frb_duration;
import 'network_source_config.dart';
import 'scan_helpers.dart';
import 'stable_hash.dart';
import 'strm_resolver.dart';

/// WebDAV 音乐服务器服务（桌面端）。
///
/// 基于 [wd.Client]（basic/digest/匿名自动协商）访问远程 WebDAV 目录，
/// 递归扫描音频建索引，返回 [Track]（[TrackSource.webdav]）。
/// 播放策略由 PlayerNotifier 决定：优先 Rust 边下边播
/// （[frb_webdav.enginePlayWebdavStream]），失败回退本服务的
/// [downloadToLocal] 全量缓存。
///
/// 配置复用 [NetworkSourceConfig] 的 webdav* 字段。
class WebdavService {
  WebdavService._();

  /// 懒创建并复用的 WebDAV client（按 baseUrl|user|pass 指纹缓存）。
  static wd.Client? _client;
  static String? _clientKey;

  /// 进行中的扫描 future：扫描中再次触发则共享结果，而非静默返回空
  /// （此前 `if (_scanning) return const []` 让对话框显示「0 首」误导用户）。
  static Future<List<Track>>? _inFlightScan;

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

  /// 读取远端文本文件全文（STRM 指针等），失败/空返回 null。
  static Future<String?> readRemoteText(String davPath) async {
    final bytes = await readRemoteBytes(davPath);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
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
  ///
  /// 防重入：已有扫描在进行时等待其完成并共享结果（此前静默返回空列表，
  /// 对话框显示「0 首」误导用户）。
  static Future<List<Track>> scanWebdav({
    void Function(List<Track> batch)? onBatch,
  }) async {
    final inflight = _inFlightScan;
    if (inflight != null) return inflight;
    final f = _scanWebdavNow(onBatch: onBatch);
    _inFlightScan = f;
    try {
      return await f;
    } finally {
      if (identical(_inFlightScan, f)) _inFlightScan = null;
    }
  }

  static Future<List<Track>> _scanWebdavNow({
    void Function(List<Track> batch)? onBatch,
  }) async {
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
    }
    if (onBatch != null && tracks.isNotEmpty) {
      for (var i = 0; i < tracks.length; i += 20) {
        final end = (i + 20).clamp(0, tracks.length);
        onBatch(tracks.sublist(i, end));
      }
    }
    return tracks;
  }

  /// 处理单个目录条目：音频并发拉真实时长建 [Track]，子目录并发递归。
  /// 同层子目录用 [Future.wait] 并发列举（HTTP 客户端串行度由服务端/连接池限制）。
  static Future<List<Track>> _scanEntries(
    wd.Client client,
    List<wd.File> entries,
    String path,
  ) async {
    final dirs = <String>[];
    final fileFutures = <Future<Track?>>[];
    for (final entry in entries) {
      final entryPath = entry.path;
      if (entryPath == null || entryPath.isEmpty) continue;
      if (entry.isDir == true) {
        dirs.add(entryPath);
      } else {
        fileFutures.add(_toTrack(entry));
      }
    }
    // 并发拉取真实时长（head 模式 Range 请求，轻量），失败/探不到回退粗估。
    final resolved = await Future.wait(fileFutures);
    final tracks = <Track>[];
    for (final t in resolved) {
      if (t != null) tracks.add(t);
    }
    if (dirs.isNotEmpty) {
      final subs = await Future.wait(dirs.map((d) => _scanSubtree(client, d)));
      for (final r in subs) {
        tracks.addAll(r);
      }
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

  static Future<Track?> _toTrack(wd.File entry) async {
    final name = entry.name ?? '';
    final path = entry.path ?? '';
    if (name.isEmpty || path.isEmpty) return null;
    final ext = name.split('.').last.toLowerCase();
    // STRM 指针文件：按歌建索引（标题取 strm 文件名），播放时读内容解析
    // 真实目标再走对应源（strm 是文本，无音频标签可读）。
    if (ext == 'strm') {
      return _toStrmTrack(entry);
    }
    if (!audioExtensions.contains('.$ext')) return null;

    var (artist, title) = parseArtistTitle(name);

    // 扫描期读一次头部同时拿「真实标签 + 时长」（Range 请求 + lofty），
    // 与封面提取解耦：无内嵌封面也能回填专辑/艺术家（对齐 NAS 扫描）。
    // 探不到回退文件名解析 + 1000kbps 粗估。
    final Duration durationHint;
    final bool durationEstimated;
    frb_duration.HeadMetadataDto? meta;
    final url = fullUrlFor(path);
    if (url != null) {
      meta = await frb_duration.getWebdavMetadata(
        url: url,
        username: username,
        password: password,
        headLimit: BigInt.from(4 * 1024 * 1024),
      );
    }
    final m = meta;
    String albumName = _albumPlaceholder;
    if (m != null) {
      final t = m.title?.trim();
      if (t != null && t.isNotEmpty) title = t;
      final a = m.artist?.trim();
      if (a != null && a.isNotEmpty) artist = a;
      final al = m.album?.trim();
      if (al != null && al.isNotEmpty) albumName = al;
      if (m.durationSecs > 0) {
        durationHint = Duration(milliseconds: (m.durationSecs * 1000).round());
        durationEstimated = false;
      } else {
        durationHint = estimateDuration(entry.size?.toInt() ?? 0);
        durationEstimated = true;
      }
    } else {
      durationHint = estimateDuration(entry.size?.toInt() ?? 0);
      durationEstimated = true;
    }

    return Track(
      id: 'dav_${fnv1a(path)}',
      title: title,
      artist: artist == 'Unknown Artist' ? _artistPlaceholder : artist,
      album: albumName,
      source: TrackSource.webdav,
      remotePath: path,
      durationHint: durationHint,
      durationEstimated: durationEstimated,
      trackNumber: m?.trackNumber,
      fileSize: entry.size?.toInt(),
    );
  }

  /// STRM 指针文件建索引：读文本解析真实目标（失败不阻断，仅落地不到目标，
  /// 播放时再兜底重试）。标题取 strm 文件名；`#EXTINF` 可携带展示标题/时长。
  static Future<Track?> _toStrmTrack(wd.File entry) async {
    final name = entry.name ?? '';
    final path = entry.path ?? '';
    if (name.isEmpty || path.isEmpty) return null;
    final (artist, title) = parseArtistTitle(name);

    final text = await readRemoteText(path);
    StrmTarget? target;
    if (text != null) {
      target = parseStrmContent(text, fromWebdav: true, strmPath: path);
    }

    var t = title;
    var a = artist == 'Unknown Artist' ? _artistPlaceholder : artist;
    Duration? dur;
    if (target != null) {
      if (target.extInfTitle != null) {
        final (pa, pt) = parseArtistTitle(target.extInfTitle!);
        t = pt;
        a = pa;
      }
      if (target.extInfSecs != null) dur = Duration(seconds: target.extInfSecs!);
    }

    return Track(
      id: 'dav_strm_${fnv1a(path)}',
      title: t,
      artist: a,
      album: _albumPlaceholder,
      source: TrackSource.webdav,
      remotePath: path,
      strmPath: path,
      strmFromWebdav: true,
      targetUri: target?.path,
      targetKind: target?.kind,
      durationHint: dur,
      durationEstimated: dur == null,
      fileSize: null,
    );
  }

  // ── 下载缓存（边下边播失败时的回退；亦可用于离线） ──

  static Future<String?> _cacheTargetFor(String davPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.webdav_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = davPath.split('/').last;
      return '${cacheDir.path}/${fnv1a(davPath)}_$name';
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
      final localFile = File('${cacheDir.path}/${fnv1a(davPath)}_$name');
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
    // 索引数组：按分片下标落位（非闭包完成顺序），保证拼接顺序正确。
    final partFiles = List<File?>.filled(_parallelChunks, null);
    try {
      final total = await frb_webdav.engineWebdavFileSize(
        url: url,
        username: username,
        password: password,
      );
      if (total <= BigInt.zero) return false;
      final size = total.toInt();
      // 大文件不分片：每片 = size/4 整块进 Dart 堆，几百 MB 的 DSD/hi-res
      // 会造成内存尖峰；50MB 以上直接回退顺序流式下载（与 mobile 对齐）。
      if (size > 50 * 1024 * 1024) {
        debugPrint('[WebdavService] 文件过大（$size B），跳过并行分片改用顺序下载');
        return false;
      }
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
            partFiles[i] = part;
          }(),
      ]);
      final sink = tmpFile.openWrite();
      try {
        var written = 0;
        // 严格按分片索引 0..n-1 顺序拼接，避免并发完成顺序导致的错位/损坏。
        for (var i = 0; i < _parallelChunks; i++) {
          final part = partFiles[i];
          if (part == null) continue;
          await sink.addStream(part.openRead());
          written += await part.length();
          onProgress?.call(written, size);
        }
      } finally {
        await sink.close();
      }
      // 完整性校验：拼接结果必须等于远端文件大小，短读/截断不能进入
      // 正式缓存（否则下次播放命中截断文件）。不符先删掉拼接物，再返回
      // false 回退顺序下载（read2File 重写 tmpFile）。
      if (await tmpFile.length() != size) {
        debugPrint(
            '[WebdavService] 分片拼接长度不符（${await tmpFile.length()}/$size B），回退顺序下载');
        await tmpFile.delete();
        return false;
      }
      return true;
    } catch (e) {
      lastError = '$e';
      return false;
    } finally {
      for (final part in partFiles) {
        if (part == null) continue;
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }
}
