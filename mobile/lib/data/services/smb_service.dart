import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smb_connect/smb_connect.dart';
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';
import 'rust_service.dart' as rs;

/// SMB 直挂服务
///
/// 通过 SMB/CIFS 协议直接访问 NAS 共享目录，
/// 扫描、读取文件并将音频导入本地。
class SmbService {
  SmbService._();

  static SmbConnect? _connection;

  static bool get isConnected => _connection != null;

  static Future<bool> connect({
    required String host,
    required String username,
    required String password,
    String domain = '',
  }) async {
    try {
      final conn = await SmbConnect.connectAuth(
        host: host,
        domain: domain,
        username: username,
        password: password,
      );
      _connection = conn;
      return true;
    } catch (e) {
      debugPrint('[SMB] connect failed: $e');
      return false;
    }
  }

  static Future<void> disconnect() async {
    await _connection?.close();
    _connection = null;
  }

  static Future<List<String>> listShares() async {
    if (_connection == null) return [];
    try {
      final shares = await _connection!.listShares();
      return shares.map((s) => s.path).toList();
    } catch (e) {
      debugPrint('[SMB] listShares failed: $e');
      return [];
    }
  }

  static Future<List<SmbFile>> listFiles(String sharePath) async {
    if (_connection == null) return [];
    try {
      final folder = await _connection!.file(sharePath);
      return await _connection!.listFiles(folder);
    } catch (e) {
      debugPrint('[SMB] listFiles failed: $e');
      return [];
    }
  }

  /// 递归扫描 SMB 共享目录中的音频文件
  static Future<List<Song>> scanSmbLibrary(String sharePath) async {
    if (_connection == null) return [];

    final songs = <Song>[];

    try {
      await _scanDirectory(sharePath, songs);
    } catch (e) {
      debugPrint('[SMB] scanSmbLibrary failed: $e');
    }

    return songs;
  }

  static Future<void> _scanDirectory(String path, List<Song> songs) async {
    if (_connection == null) return;

    try {
      final folder = await _connection!.file(path);
      final files = await _connection!.listFiles(folder);

      for (final file in files) {
        if (file.isDirectory != false) {
          await _scanDirectory(file.path, songs);
        } else if (_isAudio(file.path)) {
          final song = await _smbFileToSong(file);
          if (song != null) songs.add(song);
        }
      }
    } catch (e) {
      debugPrint('[SMB] scan directory $path failed: $e');
    }
  }

  static bool _isAudio(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ImportService.extensions.contains(ext);
  }

  /// 将 SMB 文件复制到本地、提取元数据，创建可播放的 Song 对象。
  /// 本地副本保存在 Documents/.smb_cache/ 中，后续直接播放无需再次下载。
  static Future<Song?> _smbFileToSong(SmbFile file) async {
    final smbPath = file.path;
    final name = smbPath.split('/').last;
    final fallbackTitle = name.replaceAll(RegExp(r'\.[^.]+$'), '');

    try {
      // 检查本地缓存
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.smb_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final localFile = File('${cacheDir.path}/${smbPath.hashCode}_$name');

      String localPath;
      if (await localFile.exists() && await localFile.length() > 0) {
        localPath = localFile.path;
      } else {
        // 从 SMB 下载到本地
        final raf = await _connection!.open(file);
        final fileSize = await raf.length();
        final bytes = await raf.read(fileSize);
        await raf.close();
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
      // 降级：元数据提取失败，仍创建占位 Song（但不保证可播放）
      debugPrint('[SMB] 文件处理失败 ($smbPath): $e');
      return null;
    }
  }

  /// 从 NAS 读取音频文件并复制到本地 Documents/Imported/
  static Future<String?> copyToLocal(SmbFile smbFile) async {
    if (_connection == null) return null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final importDir = Directory('${appDir.path}/Imported');
      if (!await importDir.exists()) await importDir.create(recursive: true);

      final name = smbFile.path.split('/').last;
      final dest = File('${importDir.path}/$name');

      if (await dest.exists()) return dest.path;

      final raf = await _connection!.open(smbFile);
      final fileSize = await raf.length();
      final bytes = await raf.read(fileSize);
      await raf.close();

      await dest.writeAsBytes(bytes);
      return dest.path;
    } catch (e) {
      debugPrint('[SMB] copyToLocal failed: $e');
      return null;
    }
  }
}
