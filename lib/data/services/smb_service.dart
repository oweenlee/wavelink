import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smb_connect/smb_connect.dart';
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';

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

  static Future<void> _scanDirectory(
    String path,
    List<Song> songs,
  ) async {
    if (_connection == null) return;

    try {
      final folder = await _connection!.file(path);
      final files = await _connection!.listFiles(folder);

      for (final file in files) {
        if (file.isDirectory != false) {
          await _scanDirectory(file.path, songs);
        } else if (_isAudio(file.path)) {
          final song = _fileToSong(file);
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

  static Song? _fileToSong(SmbFile file) {
    final name = file.path.split('/').last;
    final title = name.replaceAll(RegExp(r'\.[^.]+$'), '');

    return Song(
      id: 'smb_${file.path.hashCode}',
      title: title,
      artist: 'Unknown Artist',
      album: 'NAS Music',
      duration: ImportService.estimateDuration(0),
      dominantColor: _colorFromPath(file.path),
      path: file.path,
    );
  }

  static Color _colorFromPath(String path) {
    final hash = path.hashCode;
    final palette = AppTheme.palette;
    return palette[hash.abs() % palette.length];
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