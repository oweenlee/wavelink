import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../src/rust/api/smb.dart' as frb_smb;
import '../src/rust/api/duration.dart' as frb_duration;
import 'network_source_config.dart';
import 'scan_helpers.dart';
import 'stable_hash.dart';
import 'strm_resolver.dart';

/// NAS 连接状态（侧栏展示 + 播放前保活判定用）。
enum NasConnectionState { disconnected, connecting, connected, error }

/// NAS (SMB) 音乐服务（桌面端）。
///
/// 经 Rust `smb2` 绑定访问 NAS 共享：先 [connect]（smbConnect + smbConnectShare）
/// 建立会话，再 [scan] 递归列出共享内音频建索引，返回 [Track]
/// （[TrackSource.nas]，[remotePath] 为共享内相对路径）。
///
/// 播放策略由 PlayerController 决定：优先 Rust 边下边播
/// （[frb_smb.enginePlaySmbStream]），失败回退全量下载。
///
/// 连接状态经 [stateStream] 广播，UI 据此显示「已连接 / 连接中 / 错误」。
class NasService {
  NasService._();

  static NasConnectionState _state = NasConnectionState.disconnected;
  static String? lastError;

  static final _stateSC = StreamController<NasConnectionState>.broadcast();
  static Stream<NasConnectionState> get stateStream => _stateSC.stream;
  static NasConnectionState get state => _state;

  static bool get isConfigured {
    final c = NetworkSourceConfig.instance;
    return (c.nasHost?.isNotEmpty ?? false) &&
        (c.nasShare?.isNotEmpty ?? false);
  }

  static void _setState(NasConnectionState s) {
    _state = s;
    if (!_stateSC.isClosed) _stateSC.add(s);
  }

  /// 建立 SMB 会话：连接服务器 + 挂载共享。返回 null 成功，否则错误。
  ///
  /// 已连接时先用 [keepalive] 探测会话是否仍存活（Dart 侧的 [_state] 是缓存，
  /// 可能因超时/后台/临时测试断开而陈旧），不健康则强制重建。这能避免
  /// 「状态显示已连接，实际 Rust SESSION 已清空」导致的 `not connected` 误报。
  ///
  /// 并发调用时**等待进行中的连接完成**而非当成成功返回：此前
  /// `_state==connecting` 直接 `return null`，调用方（scan 等）会在连接真正
  /// 建立前就发 SMB 请求 → 误报失败。
  static Future<String?> connect() async {
    if (!isConfigured) return 'NAS 未配置（需 host + share）';
    if (_state == NasConnectionState.connected) {
      final healthy = await keepalive();
      if (healthy) {
        debugPrint('[NasService.connect] session alive, reuse');
        return null;
      }
      debugPrint('[NasService.connect] cached connected but session dead, reconnect');
      _setState(NasConnectionState.disconnected);
    }
    final inflight = _connecting;
    if (inflight != null) return inflight;
    final f = _doConnect();
    _connecting = f;
    try {
      return await f;
    } finally {
      if (identical(_connecting, f)) _connecting = null;
    }
  }

  static Future<String?>? _connecting;

  static Future<String?> _doConnect() async {
    _setState(NasConnectionState.connecting);
    try {
      final c = NetworkSourceConfig.instance;
      debugPrint('[NasService.connect] smbConnect host=${c.nasHost}:${c.nasPort}');
      await frb_smb.smbConnect(
        host: c.nasHost!,
        port: c.nasPort,
        username: c.nasUsername ?? '',
        password: c.nasPassword,
        domain: c.nasDomain,
      );
      debugPrint('[NasService.connect] smbConnectShare share=${c.nasShare}');
      await frb_smb.smbConnectShare(shareName: c.nasShare!);
      _setState(NasConnectionState.connected);
      debugPrint('[NasService.connect] connected');
      return null;
    } catch (e) {
      lastError = '$e';
      debugPrint('[NasService.connect] error: $e');
      _setState(NasConnectionState.error);
      return lastError;
    }
  }

  /// 断开并清理会话（含读取池）。
  static Future<void> disconnect() async {
    try {
      await frb_smb.smbDisconnect();
    } catch (_) {}
    _setState(NasConnectionState.disconnected);
  }

  /// 列出服务器所有共享（配置页选择共享名用）。
  static Future<List<frb_smb.SmbShareInfo>> listShares() =>
      frb_smb.smbListShares();

  /// 仅连接服务器（不挂载共享）并列出所有共享，供配置页「列出共享」选择共享名。
  ///
  /// 用完立即断开，**不污染**已保存的持久会话（[connect] 才建立持久会话）。
  /// 与 [testConnection] 同理是临时握手：先 [smbConnect] 建立 client，
  /// 再 [smbListShares]，最后 [smbDisconnect]。失败直接抛异常，由调用方提示。
  static Future<List<frb_smb.SmbShareInfo>> listSharesConnected({
    required String host,
    required int port,
    required String username,
    required String password,
    String domain = '',
  }) async {
    // 已建立持久会话时先探测，健康则直接列举；不健康把状态清掉，避免后续
    // connect() 因 _state==connected 而跳过真正的重连。
    if (_state == NasConnectionState.connected) {
      final healthy = await keepalive();
      if (healthy) return frb_smb.smbListShares();
      _setState(NasConnectionState.disconnected);
    }
    await frb_smb.smbConnect(
      host: host,
      port: port,
      username: username,
      password: password,
      domain: domain,
    );
    try {
      return await frb_smb.smbListShares();
    } finally {
      await frb_smb.smbDisconnect();
      // 临时会话已断开；若此前 _state 被缓存为 connected，必须重置，
      // 否则 scan() 里的 connect() 会误判为已连接而跳过重建。
      if (_state == NasConnectionState.connected) {
        _setState(NasConnectionState.disconnected);
      }
    }
  }

  /// 不落盘的连接测试：用临时参数握手 + 挂载共享，返回 null 成功，否则错误。
  /// 测试后断开，避免污染已保存会话（[connect] 才建立持久会话）。
  static Future<String?> testConnection({
    required String host,
    required int port,
    required String share,
    required String username,
    required String password,
    String domain = '',
  }) async {
    try {
      await frb_smb.smbConnect(
        host: host,
        port: port,
        username: username,
        password: password,
        domain: domain,
      );
      await frb_smb.smbConnectShare(shareName: share);
      await frb_smb.smbDisconnect();
      return null;
    } catch (e) {
      try {
        await frb_smb.smbDisconnect();
      } catch (_) {}
      return '$e';
    } finally {
      // 测试函数使用全局 SESSION 做临时握手；无论成败，断开之后 Dart 缓存状态
      // 必须重置，否则 _state==connected 会让后续 connect() 跳过重建。
      if (_state == NasConnectionState.connected) {
        _setState(NasConnectionState.disconnected);
      }
    }
  }

  /// 前台保活：对主会话 + 读取池每条连接发 fs_info，不健康则重建。
  static Future<bool> keepalive() async {
    try {
      return await frb_smb.smbKeepalive();
    } catch (e) {
      lastError = '$e';
      _setState(NasConnectionState.error);
      return false;
    }
  }

  /// 递归扫描共享内音频，按 [onBatch] 增量回调（每 20 首一批）。
  /// 未连接时自动 [connect]，失败返回错误而非静默空列表。
  ///
  /// 目录遍历**并行化**：同一层的子目录用 [Future.wait] 并发列出，
  /// 实际并发数由 Rust 侧 SMB 读取池（10 条连接）限流。相比原先的
  /// 逐目录串行递归，大共享（成百上千目录）扫描速度提升一个数量级。
  ///
  /// 防重入：已有扫描在进行时等待其完成并共享结果（此前无 guarding，
  /// 双击/重复触发会并发扫两份，且第二次在连接建立前就失败误报）。
  static Future<List<Track>> scan({
    void Function(List<Track> batch)? onBatch,
  }) async {
    final inflight = _scanning;
    if (inflight != null) return inflight;
    final f = _scanNow(onBatch: onBatch);
    _scanning = f;
    try {
      return await f;
    } finally {
      if (identical(_scanning, f)) _scanning = null;
    }
  }

  static Future<List<Track>>? _scanning;

  static Future<List<Track>> _scanNow({
    void Function(List<Track> batch)? onBatch,
  }) async {
    final err = await connect();
    if (err != null) {
      lastError = err;
      return const [];
    }
    // 根目录单独列出：失败直接冒泡（如共享根无列举权限 / 部分 NAS 对根
    // 路径行为异常），否则会被子目录隔离逻辑静默吞掉 → 「已连接却列表空、无提示」。
    List<frb_smb.SmbDirEntry> root;
    try {
      root = await frb_smb.smbListDirectory(path: '');
    } catch (e) {
      lastError = '列出共享根目录失败：$e';
      _setState(NasConnectionState.error);
      return const [];
    }
    final tracks = await _scanEntries(root, '');
    if (onBatch != null && tracks.isNotEmpty) {
      for (var i = 0; i < tracks.length; i += 20) {
        final end = (i + 20).clamp(0, tracks.length);
        onBatch(tracks.sublist(i, end));
      }
    }
    return tracks;
  }

  /// 处理单个目录的条目：音频并发拉真实时长建 [Track]，子目录并发递归。
  static Future<List<Track>> _scanEntries(
    List<frb_smb.SmbDirEntry> entries,
    String path,
  ) async {
    final dirs = <String>[];
    final fileFutures = <Future<Track?>>[];
    for (final entry in entries) {
      if (entry.name == '.' || entry.name == '..') continue;
      if (entry.isDir) {
        dirs.add(path.isEmpty ? entry.name : p.join(path, entry.name));
      } else {
        fileFutures.add(_toTrack(path, entry));
      }
    }
    // 并发拉取真实时长（SMB 连接池限流到 ~10 并发），失败/探不到回退粗估。
    final resolved = await Future.wait(fileFutures);
    final tracks = <Track>[];
    for (final t in resolved) {
      if (t != null) tracks.add(t);
    }
    // 同层子目录并发扫描（SMB 连接池限流到 ~10 并发）。
    if (dirs.isNotEmpty) {
      final subs = await Future.wait(dirs.map(_scanSubtree));
      for (final r in subs) {
        tracks.addAll(r);
      }
    }
    return tracks;
  }

  /// 递归扫描单个子目录；列举失败重试一次后仍失败则隔离跳过（返回空），
  /// 不影响其余目录。NAS 高并发/连接波动时偶发列举失败，重试可显著减少
  /// 整目录丢失（用户曲库“感觉少了几百首”的常见来源：某目录一次失败
  /// 即被静默跳过）。
  static Future<List<Track>> _scanSubtree(String path) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final entries = await frb_smb.smbListDirectory(path: path);
        return await _scanEntries(entries, path);
      } catch (e) {
        if (attempt == 0) {
          debugPrint('[NasService] 子目录列举失败(重试1次): $path -> $e');
          // 间隔短暂重试：闪过性连接问题（池连接恰被回收等）
          await Future<void>.delayed(const Duration(milliseconds: 300));
        } else {
          debugPrint('[NasService] 子目录列举失败(重试仍失败,隔离跳过): '
              '$path -> $e');
        }
      }
    }
    return const [];
  }

  static Future<Track?> _toTrack(String dirPath, frb_smb.SmbDirEntry entry) async {
    final name = entry.name;
    if (name.isEmpty) return null;
    // STRM 指针文件：按歌建索引（标题取 strm 文件名），不读音频标签
    // （strm 是文本无音频标签）。Resolver 落地真实目标，播放时再分发。
    if (isStrmName(name)) {
      return _toStrmTrack(dirPath, entry);
    }
    final ext = name.split('.').last.toLowerCase();
    if (!audioExtensions.contains('.$ext')) return null;
    final smbPath = dirPath.isEmpty ? name : p.join(dirPath, name);

    var (artist, title) = parseArtistTitle(name);

    // 扫描期读一次头部同时拿「真实标签 + 时长」（lofty 内存探测，
    // SMB 连接池限流并发），与封面提取解耦：无内嵌封面也能回填
    // 专辑/艺术家，不再全挤在占位「NAS Music / Unknown Artist」里。
    // 探不到（如 OGG 需尾部页）回退文件名解析 + 1000kbps 粗估。
    final meta = await frb_duration.getNasMetadata(
      path: smbPath,
      headLimit: BigInt.from(4 * 1024 * 1024),
    );
    final Duration durationHint;
    final bool durationEstimated;
    if (meta != null) {
      if (meta.title != null && meta.title!.trim().isNotEmpty) {
        title = meta.title!.trim();
      }
      if (meta.artist != null && meta.artist!.trim().isNotEmpty) {
        artist = meta.artist!.trim();
      }
      if (meta.durationSecs > 0) {
        durationHint =
            Duration(milliseconds: (meta.durationSecs * 1000).round());
        durationEstimated = false;
      } else {
        durationHint = estimateDuration(entry.size.toInt());
        durationEstimated = true;
      }
    } else {
      durationHint = estimateDuration(entry.size.toInt());
      durationEstimated = true;
    }

    return Track(
      id: 'nas_${fnv1a(smbPath)}',
      title: title,
      artist: artist == 'Unknown Artist' ? 'Unknown Artist' : artist,
      album: meta != null &&
              meta.album != null &&
              meta.album!.trim().isNotEmpty
          ? meta.album!.trim()
          : 'NAS Music',
      source: TrackSource.nas,
      remotePath: smbPath,
      durationHint: durationHint,
      durationEstimated: durationEstimated,
      trackNumber: meta?.trackNumber,
      fileSize: entry.size.toInt(),
    );
  }

  /// STRM 指针文件建索引：读文本解析真实目标（失败不阻断，仅落地不到目标，
  /// 播放时再兜底重试）。标题取 strm 文件名；`#EXTINF` 可携带展示标题/时长。
  static Future<Track?> _toStrmTrack(
    String dirPath,
    frb_smb.SmbDirEntry entry,
  ) async {
    final name = entry.name;
    final smbPath = dirPath.isEmpty ? name : p.join(dirPath, name);
    final (artist, title) = parseArtistTitle(name);

    final text = await readStrmText(smbPath);
    StrmTarget? target;
    if (text != null) {
      target = parseStrmContent(text, fromWebdav: false, strmPath: smbPath);
    }

    var t = title;
    var a = artist == 'Unknown Artist' ? 'Unknown Artist' : artist;
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
      id: 'nas_strm_${fnv1a(smbPath)}',
      title: t,
      artist: a,
      album: 'NAS Music',
      source: TrackSource.nas,
      remotePath: smbPath,
      strmPath: smbPath,
      strmFromWebdav: false,
      targetUri: target?.path,
      targetKind: target?.kind,
      durationHint: dur,
      durationEstimated: dur == null,
      fileSize: null,
    );
  }

  /// 读取 STRM 文本文件全文（SMB 整文件读，strm 很小）。失败/空返回 null。
  static Future<String?> readStrmText(String smbPath) async {
    try {
      final bytes = await frb_smb.smbReadFile(path: smbPath);
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      debugPrint('[NasService.readStrmText] $smbPath -> $e');
      return null;
    }
  }

  /// 缓存目标路径（供播放分发复用，边下边播与回退下载命中同一缓存）。
  static Future<String?> cachePathFor(String smbPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.nas_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = smbPath.split('/').last;
      return '${cacheDir.path}/${fnv1a(smbPath)}_$name';
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 缓存命中检查（存在且非空即命中）；命名规则与 [cachePathFor] 一致。
  /// 供播放前短路：已缓存的歌本地直播，不再重新从远端拉流。
  static Future<String?> cachedLocalPath(String smbPath) async {
    try {
      final target = await cachePathFor(smbPath);
      if (target == null) return null;
      final localFile = File(target);
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      return null;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 回退：整曲流式读入本地缓存（512KB 分块，不整曲进内存），
  /// 先写 `.part` 再原子改名——中断/失败不留下半截缓存被后续误命中。
  /// 完整性校验：以远端实时大小为准（曲库 fileSize 可能过期，仅作兼容回退），
  /// 短读/截断直接丢弃，避免"坏缓存永久命中"。
  static Future<String?> downloadToLocal(Track track) {
    final smbPath = track.remotePath;
    if (smbPath == null) return Future.value(null);
    return _downloadToLocal(smbPath, track.fileSize);
  }

  /// 按 smb 路径回退下载（STRM 的 smb 目标无完整 [Track]，用路径版）。
  /// 逻辑与 [downloadToLocal] 一致。
  static Future<String?> downloadToLocalPath(String smbPath) =>
      _downloadToLocal(smbPath, null);

  static Future<String?> _downloadToLocal(String smbPath, int? sizeHint) async {
    File? tmpFile;
    try {
      final target = await cachePathFor(smbPath);
      if (target == null) return null;
      final localFile = File(target);
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      tmpFile = File('${localFile.path}.part');
      final sink = tmpFile.openWrite();
      var written = 0;
      try {
        await for (final chunk in frb_smb.smbReadFileStream(path: smbPath)) {
          sink.add(chunk);
          written += chunk.length;
        }
      } finally {
        await sink.close();
      }
      if (written == 0) {
        await tmpFile.delete();
        return null;
      }
      // 完整性校验：优先远端实时大小（扫描期 fileSize 在远端文件变更后会
      // 过期，仅作探测失败时的兼容回退）。
      int? expected;
      try {
        expected = (await frb_smb.smbFileSize(path: smbPath)).toInt();
      } catch (_) {
        expected = sizeHint;
      }
      if (expected != null && expected > 0 && written != expected) {
        debugPrint(
            '[NasService] 下载不完整（$written/${expected}B），丢弃: $smbPath');
        await tmpFile.delete();
        return null;
      }
      await tmpFile.rename(localFile.path);
      return localFile.path;
    } catch (e) {
      lastError = '$e';
      if (tmpFile != null) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
      }
      return null;
    }
  }
}
