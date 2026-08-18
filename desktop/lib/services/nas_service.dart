import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../src/rust/api/smb.dart' as frb_smb;
import 'network_source_config.dart';
import 'scan_helpers.dart';

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
    if (_state == NasConnectionState.connecting) return null;
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
  static Future<List<Track>> scan({
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

  /// 处理单个目录的条目：音频直接建 [Track]，子目录并发递归。
  static Future<List<Track>> _scanEntries(
    List<frb_smb.SmbDirEntry> entries,
    String path,
  ) async {
    final dirs = <String>[];
    final tracks = <Track>[];
    for (final entry in entries) {
      if (entry.name == '.' || entry.name == '..') continue;
      if (entry.isDir) {
        dirs.add(path.isEmpty ? entry.name : p.join(path, entry.name));
      } else {
        final track = _toTrack(path, entry);
        if (track != null) tracks.add(track);
      }
    }
    // 同层子目录并发扫描（SMB 连接池限流到 ~10 并发）。
    if (dirs.isNotEmpty) {
      final subs = await Future.wait(dirs.map(_scanSubtree));
      for (final r in subs) tracks.addAll(r);
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

  static Track? _toTrack(String dirPath, frb_smb.SmbDirEntry entry) {
    final name = entry.name;
    if (name.isEmpty) return null;
    final ext = name.split('.').last.toLowerCase();
    if (!audioExtensions.contains('.$ext')) return null;
    final smbPath = dirPath.isEmpty ? name : p.join(dirPath, name);

    final (artist, title) = parseArtistTitle(name);
    return Track(
      id: 'nas_${smbPath.hashCode}',
      title: title,
      artist: artist == 'Unknown Artist' ? 'Unknown Artist' : artist,
      album: 'NAS Music',
      source: TrackSource.nas,
      remotePath: smbPath,
      durationHint: estimateDuration(entry.size.toInt()),
      durationEstimated: true,
      fileSize: entry.size.toInt(),
    );
  }

  /// 缓存目标路径（供播放分发复用，边下边播与回退下载命中同一缓存）。
  static Future<String?> cachePathFor(String smbPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.nas_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = smbPath.split('/').last;
      return '${cacheDir.path}/${smbPath.hashCode}_$name';
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 回退：整曲读入本地缓存后由引擎播放（边下边播失败时使用）。
  static Future<String?> downloadToLocal(Track track) async {
    final smbPath = track.remotePath;
    if (smbPath == null) return null;
    try {
      final target = await cachePathFor(smbPath);
      if (target == null) return null;
      final localFile = File(target);
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      final bytes = await frb_smb.smbReadFile(path: smbPath);
      if (bytes.isEmpty) return null;
      await localFile.writeAsBytes(bytes, flush: true);
      return localFile.path;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }
}
