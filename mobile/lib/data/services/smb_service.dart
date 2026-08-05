import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/song.dart';
import '../../src/rust/api/smb.dart' as smb;
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';
import 'rust_service.dart' as rs;

/// SMB 直挂服务
///
/// 基于 Rust `smb2` crate（经 flutter_rust_bridge 绑定）直接访问 NAS 共享目录，
/// 扫描、读取文件并将音频导入本地。空用户名/密码即 guest（匿名）访问。
class SmbService {
  SmbService._();

  static bool _connected = false;

  /// 扫描进行中标记：期间禁止 connect/disconnect 重建或销毁会话，
  /// 否则扫描中的 read 会因 tree 被重置而报 "no share connected"。
  static bool _scanning = false;

  /// 最近一次操作的具体错误信息（用于 UI 展示排查）
  static String? lastError;

  static bool get isConnected => _connected;

  /// 连接 SMB 服务器（host 为裸 IP/域名，内部拼 :port）。
  /// 共享挂载在扫描/列目录前按需调用 [connectShare]。
  static Future<bool> connect({
    required String host,
    required String username,
    required String password,
    String domain = '',
    int port = 445,
  }) async {
    // 扫描进行中：复用现有会话，不重建（重建会把 tree 重置为 None）
    if (_scanning && _connected) return true;
    try {
      await smb.smbConnect(
        host: host,
        port: port,
        username: username,
        password: password,
        domain: domain,
      );
      _connected = true;
      lastError = null;
      return true;
    } catch (e) {
      debugPrint('[SMB] connect failed: $e');
      _connected = false;
      lastError = '$e';
      return false;
    }
  }

  /// 挂载共享（后续 list/read 均相对该共享根目录）
  static Future<bool> connectShare(String shareName) async {
    if (!_connected) return false;
    try {
      await smb.smbConnectShare(shareName: shareName);
      lastError = null;
      return true;
    } catch (e) {
      debugPrint('[SMB] connectShare $shareName failed: $e');
      lastError = '$e';
      return false;
    }
  }

  static Future<void> disconnect() async {
    // 扫描进行中：保持会话，避免打断扫描
    if (_scanning) return;
    try {
      await smb.smbDisconnect();
    } catch (e) {
      debugPrint('[SMB] disconnect failed: $e');
    }
    _connected = false;
  }

  /// 列出服务器所有共享（返回共享名）
  static Future<List<String>> listShares() async {
    if (!_connected) return [];
    try {
      final shares = await smb.smbListShares();
      return shares.map((s) => s.name).toList();
    } catch (e) {
      debugPrint('[SMB] listShares failed: $e');
      return [];
    }
  }

  /// 列出共享内目录内容
  static Future<List<smb.SmbDirEntry>> listFiles(String path) async {
    if (!_connected) return [];
    try {
      return await smb.smbListDirectory(path: path);
    } catch (e) {
      debugPrint('[SMB] listFiles($path) failed: $e');
      return [];
    }
  }

  /// 递归扫描 SMB 共享目录中的音频文件。
  /// [sharePath] 如 "/misic" 或 "/misic/Music"：首段为共享名，其余为共享内相对路径。
  /// [onBatch] 增量回调：每下载满一批（20 首）立即回调，
  /// 供上层实时合并入库/持久化，避免全量扫完才可见。
  static Future<List<Song>> scanSmbLibrary(
    String sharePath, {
    void Function(List<Song> batch)? onBatch,
  }) async {
    if (!_connected) return [];

    final parts = sharePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return [];
    final shareName = parts.first;
    final root = parts.skip(1).join('/');

    if (!await connectShare(shareName)) return [];

    _scanning = true;
    final songs = <Song>[];
    try {
      await _scanDirectory(root, songs, onBatch);
    } catch (e) {
      debugPrint('[SMB] scanSmbLibrary failed: $e');
    } finally {
      _scanning = false;
    }
    return songs;
  }

  static Future<void> _scanDirectory(
    String relPath,
    List<Song> songs, [
    void Function(List<Song> batch)? onBatch,
  ]) async {
    try {
      final entries = await smb.smbListDirectory(path: relPath);
      final dirs = <String>[];
      final files = <(String, String, int)>[];
      for (final entry in entries) {
        // 防御：跳过 "."/".."（Rust 层已过滤，此处兜底）
        if (entry.name == '.' || entry.name == '..') continue;
        final childPath = relPath.isEmpty ? entry.name : '$relPath/${entry.name}';
        if (entry.isDir) {
          dirs.add(childPath);
        } else if (_isAudio(entry.name)) {
          files.add((childPath, entry.name, entry.size.toInt()));
        }
      }
      // 子目录串行递归（层级浅），文件并行下载（与 Rust 读取池大小对齐）
      for (final d in dirs) {
        await _scanDirectory(d, songs, onBatch);
      }
      final buffer = <Song>[];
      void flush() {
        if (buffer.isNotEmpty) {
          onBatch?.call(List.of(buffer));
          buffer.clear();
        }
      }

      var next = 0;
      Future<void> worker() async {
        while (next < files.length) {
          final i = next++;
          final f = files[i];
          final song = await _smbFileToSong(f.$1, f.$2, f.$3);
          if (song != null) {
            songs.add(song);
            buffer.add(song);
            if (buffer.length >= 20) flush();
          }
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
      flush();
    } catch (e) {
      debugPrint('[SMB] scan directory $relPath failed: $e');
    }
  }

  static bool _isAudio(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ImportService.extensions.contains(ext);
  }

  /// 将 SMB 文件复制到本地、提取元数据，创建可播放的 Song 对象。
  /// 本地副本保存在 Documents/.smb_cache/ 中，后续直接播放无需再次下载。
  static Future<Song?> _smbFileToSong(
    String smbPath,
    String name,
    int remoteSize,
  ) async {
    final fallbackTitle = name.replaceAll(RegExp(r'\.[^.]+$'), '');

    try {
      // 检查本地缓存（按远端大小判断是否有变化）
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.smb_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final localFile = File('${cacheDir.path}/${smbPath.hashCode}_$name');

      String localPath;
      final cached = await localFile.exists();
      final cachedSize = cached ? await localFile.length() : 0;
      if (cached && cachedSize > 0 && cachedSize == remoteSize) {
        localPath = localFile.path;
      } else {
        // 从 SMB 下载到本地
        final bytes = await smb.smbReadFile(path: smbPath);
        await localFile.writeAsBytes(bytes);
        localPath = localFile.path;
      }

      // 用 Rust 读取真实元数据
      String title = fallbackTitle;
      String artist = 'Unknown Artist';
      String album = 'NAS Music';
      Duration duration = ImportService.estimateDuration(
        await localFile.length(),
      );
      String? coverUrl;
      bool hasCover = false;

      if (rs.rustAvailable) {
        try {
          final meta = await rs.readMetadata(localPath);
          if (meta.title != null && meta.title!.isNotEmpty) title = meta.title!;
          if (meta.artist != null && meta.artist!.isNotEmpty) artist = meta.artist!;
          if (meta.album != null && meta.album!.isNotEmpty) album = meta.album!;
          if (meta.durationSecs > 0) {
            duration = Duration(milliseconds: (meta.durationSecs * 1000).round());
          }
          if (meta.hasCover && meta.coverBytes.isNotEmpty) {
            final coversDir = Directory('${appDir.path}/.covers');
            if (!await coversDir.exists()) await coversDir.create(recursive: true);
            final coverFile = File('${coversDir.path}/smb_${smbPath.hashCode}.jpg');
            await coverFile.writeAsBytes(meta.coverBytes);
            coverUrl = coverFile.path;
            hasCover = true;
          }
        } catch (e) {
          debugPrint('[SMB] Rust 元数据读取失败: $e');
        }
      }

      return Song(
        id: 'smb_${smbPath.hashCode}',
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        dominantColor: AppTheme.s2,
        path: localPath,
        coverUrl: coverUrl,
        hasCover: hasCover,
      );
    } catch (e) {
      // 降级：下载/元数据提取失败，返回 null 跳过该文件
      debugPrint('[SMB] 文件处理失败 ($smbPath): $e');
      return null;
    }
  }

  /// 从 NAS 读取音频文件并复制到本地 Documents/Imported/
  static Future<String?> copyToLocal(String smbPath) async {
    if (!_connected) return null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final importDir = Directory('${appDir.path}/Imported');
      if (!await importDir.exists()) await importDir.create(recursive: true);

      final name = smbPath.split('/').last;
      final dest = File('${importDir.path}/$name');

      if (await dest.exists()) return dest.path;

      final bytes = await smb.smbReadFile(path: smbPath);
      await dest.writeAsBytes(bytes);
      return dest.path;
    } catch (e) {
      debugPrint('[SMB] copyToLocal failed: $e');
      return null;
    }
  }
}
