import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/song.dart';
import 'rust_service.dart' as rs;
import 'file_picker_service.dart';
import '../../ui/core/theme/app_theme.dart';
import 'media_store_service.dart';
import 'media_store_channel.dart';
import 'subsonic_service.dart';
import 'smb_service.dart';

/// 音乐文件导入服务
///
/// 整合五种导入渠道：
/// 1. 系统音乐库扫描（Android MediaStore / iOS MPMediaQuery）→ 优先
/// 2. 文件选择器导入 → 复制到 Documents/Imported/
/// 3. Documents/ 目录扫描 → 已有文件恢复
/// 4. Subsonic / Navidrome / Jellyfin / Emby 服务器扫描 → HTTP(S)
/// 5. SMB 直挂 NAS 共享 → SMB/CIFS
class ImportService {
  static const extensions = [
    'mp3',
    'flac',
    'wav',
    'aac',
    'ogg',
    'm4a',
    'wma',
    'alac',
    'aiff',
    'dsf',
    'dff',
    'opus',
    'lrc',
  ];

  /// 系统音乐库是否可用
  static Future<bool> get isMediaStoreAvailable =>
      MediaStoreService.isAvailable;

  /// 从系统音乐库扫描（Android MediaStore / iOS MPMediaQuery）
  static Future<List<Song>> scanMediaStore() async {
    final hasPermission = await MediaStoreService.requestPermission();
    if (!hasPermission) {
      debugPrint('[Import] 系统音乐库权限被拒绝');
      return [];
    }

    final songs = await MediaStoreService.scanAll();
    if (songs.isEmpty) return [];

    // 尝试用 Rust 补全/修正元数据
    if (rs.rustAvailable) {
      await _enrichWithRustMetadata(songs);
    }

    // 异步缓存封面（不阻塞返回）
    cacheCovers(songs);
    return songs;
  }

  /// 从 app Documents/ 扫描已有音频文件和歌词文件
  static Future<List<Song>> scanDocuments() async {
    final dir = await getApplicationDocumentsDirectory();
    final audioFiles = <File>[];
    final lyricFiles = <File>[];
    if (!await dir.exists()) return [];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final ext = entity.path.split('.').last.toLowerCase();
        if (ext == 'lrc') {
          lyricFiles.add(entity);
        } else if (extensions.contains(ext)) {
          audioFiles.add(entity);
        }
      }
    }
    if (audioFiles.isEmpty) return [];

    // 匹配歌词文件到音频文件（按文件名（不含扩展名）匹配）
    final audioByBase = <String, File>{};
    for (final f in audioFiles) {
      audioByBase[_fileBaseName(f.path)] = f;
    }
    final lyricByBase = <String, String>{};
    for (final lf in lyricFiles) {
      lyricByBase[_fileBaseName(lf.path)] = lf.path;
    }

    final matchedAudioBases = audioByBase.keys.toSet().intersection(
      lyricByBase.keys.toSet(),
    );

    final songs = await _filesToSongs(audioFiles);
    for (final song in songs) {
      if (song.path != null) {
        final base = _fileBaseName(song.path!);
        if (matchedAudioBases.contains(base)) {
          song.lyricsPath = lyricByBase[base];
          song.hasLyrics = true;
        }
      }
    }
    return songs;
  }

  static String _fileBaseName(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  /// 打开文件选择器 → 复制到 Documents/Imported/
  static Future<List<Song>> pickAndImport() async {
    final paths = await FilePickerService.pickFiles();
    if (paths.isEmpty) return [];

    final appDir = await getApplicationDocumentsDirectory();
    final importDir = Directory('${appDir.path}/Imported');
    if (!await importDir.exists()) await importDir.create(recursive: true);

    final files = <File>[];
    for (final srcPath in paths) {
      final file = File(srcPath);
      final name = srcPath.split('/').last;
      final ext = name.split('.').last.toLowerCase();
      // 如果文件已在 App 目录内，不再复制
      if (srcPath.startsWith(appDir.path)) {
        files.add(file);
        continue;
      }
      final dest = File('${importDir.path}/$name');
      if (!await dest.exists()) {
        await file.copy(dest.path);
      }
      files.add(dest);

      // 如果是音频文件，也复制对应的 .lrc 歌词文件
      if (ext != 'lrc') {
        final baseName = name.replaceAll(RegExp(r'\.[^.]+$'), '');
        final lrcSrc = File(
          '${srcPath.substring(0, srcPath.lastIndexOf('/'))}/$baseName.lrc',
        );
        if (await lrcSrc.exists()) {
          final lrcDest = File('${importDir.path}/$baseName.lrc');
          if (!await lrcDest.exists()) {
            await lrcSrc.copy(lrcDest.path);
          }
        }
      }
    }
    return await _filesToSongs(files);
  }

  /// 合并系统库扫描 + Documents 扫描 + 网络扫描，去重
  static Future<List<Song>> scanAll() async {
    final mediaSongs = await scanMediaStore();
    final docSongs = await scanDocuments();

    // 按 path 去重（系统库优先）
    final seen = <String>{};
    final merged = <Song>[];
    for (final s in [...mediaSongs, ...docSongs]) {
      if (s.path != null && seen.add(s.path!)) {
        merged.add(s);
      }
    }
    return merged;
  }

  /// 从 Subsonic / Navidrome / Jellyfin / Emby 服务器扫描音乐库
  static Future<List<Song>> scanSubsonic() async {
    if (!SubsonicService.isConfigured) return [];
    return await SubsonicService.scanLibrary();
  }

  /// 从 SMB 共享扫描音频文件
  static Future<List<Song>> scanSmb(String sharePath) async {
    if (!SmbService.isConnected) return [];
    return await SmbService.scanSmbLibrary(sharePath);
  }

  // ── 内部方法 ──

  /// 用 Rust 读取真实元数据来补全/修正歌曲信息
  static Future<void> _enrichWithRustMetadata(List<Song> songs) async {
    final cacheDir = await _coverCacheDir();
    for (final song in songs) {
      if (song.path == null) continue;
      // iOS iPod library 歌曲无法以文件方式读取，跳过
      if (song.path!.startsWith('ipod-library://')) continue;
      try {
        final meta = await rs.readMetadata(song.path!);
        if (meta.title != null && meta.title!.isNotEmpty) {
          song.title = meta.title!;
        }
        if (meta.artist != null && meta.artist!.isNotEmpty) {
          song.artist = meta.artist!;
        }
        if (meta.album != null && meta.album!.isNotEmpty) {
          song.album = meta.album!;
        }
        if (meta.durationSecs > 0) {
          song.duration = Duration(
            milliseconds: (meta.durationSecs * 1000).round(),
          );
        }
        // 缓存封面
        if (meta.hasCover && meta.coverBytes.isNotEmpty) {
          try {
            final cacheFile = File(
              '${cacheDir.path}/${song.path!.hashCode}.jpg',
            );
            await cacheFile.writeAsBytes(meta.coverBytes);
            song.coverUrl = cacheFile.path;
            song.hasCover = true;
          } catch (e) {
            debugPrint('[Import] 封面缓存失败: $e');
          }
        }
      } catch (e) {
        debugPrint('[Import] Rust 元数据读取失败: $e');
      }
    }
  }

  /// 批量将文件转为 Song 对象（优先用 Rust 元数据）
  static Future<List<Song>> _filesToSongs(List<File> files) async {
    final cacheDir = await _coverCacheDir();
    final songs = <Song>[];
    for (final file in files) {
      Song? song;
      if (rs.rustAvailable) {
        try {
          final meta = await rs.readMetadata(file.path);
          final title = meta.title ?? _titleFromPath(file.path);
          final artist = meta.artist ?? 'Unknown Artist';
          final albumName = meta.album ?? 'Imported Music';
          final duration = meta.durationSecs > 0
              ? Duration(milliseconds: (meta.durationSecs * 1000).round())
              : estimateDuration(file.statSync().size);

          String? coverUrl;
          if (meta.hasCover && meta.coverBytes.isNotEmpty) {
            try {
              final cacheFile = File(
                '${cacheDir.path}/${file.path.hashCode}.jpg',
              );
              await cacheFile.writeAsBytes(meta.coverBytes);
              coverUrl = cacheFile.path;
            } catch (e) {
              debugPrint('[Import] 封面缓存失败: $e');
            }
          }

          song = Song(
            id: 'imp_${_stableHash(file.path)}',
            title: title,
            artist: artist,
            album: albumName,
            duration: duration,
            dominantColor: _colorFromPath(file.path),
            path: file.path,
            coverUrl: coverUrl,
            hasCover: meta.hasCover,
          );
        } catch (e) {
          debugPrint('[Import] Rust 元数据读取失败，降级到文件名猜测: $e');
        }
      }

      song ??= _fileToSong(file);
      // Check for matching .lrc lyrics file in same directory
      if (song.path != null) {
        final dir = File(song.path!).parent.path;
        final base = _fileBaseName(song.path!);
        final lrcFile = File('$dir/$base.lrc');
        if (await lrcFile.exists()) {
          song.lyricsPath = lrcFile.path;
          song.hasLyrics = true;
        }
      }
      songs.add(song);
    }
    return songs;
  }

  static String _titleFromPath(String path) {
    final name = path.split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  /// FNV-1a 64-bit hash，比 Dart hashCode 碰撞概率低得多
  static String _stableHash(String input) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static Duration estimateDuration(int fileSizeBytes) {
    final sizeMb = (fileSizeBytes / (1024 * 1024)).clamp(0.1, 9999);
    final estMin = (sizeMb / 1.2).ceil().clamp(1, 999);
    return Duration(minutes: estMin);
  }

  static Color _colorFromPath(String path) {
    final hash = path.hashCode;
    final palette = AppTheme.palette;
    return palette[hash.abs() % palette.length];
  }

  static Future<Directory> _coverCacheDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/.covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Song _fileToSong(File file) {
    final name = file.path.split('/').last;
    final title = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    return Song(
      id: 'imp_${_stableHash(file.path)}',
      title: title,
      artist: '未知艺术家',
      album: '导入的音乐',
      duration: ImportService.estimateDuration(file.statSync().size),
      dominantColor: _colorFromPath(file.path),
      path: file.path,
    );
  }

  /// 异步缓存所有封面（不阻塞返回）
  static Future<void> cacheCovers(List<Song> songs) async {
    final cacheDir = await _coverCacheDir();
    for (final song in songs) {
      if (song.path == null || song.coverUrl != null) continue;

      // iOS: 通过平台通道获取封面
      if (Platform.isIOS) {
        await _cacheIOSCover(song, cacheDir);
        continue;
      }

      // Android: 用 Rust 提取封面
      if (!rs.rustAvailable) continue;
      try {
        final bytes = await rs.getCoverBytes(song.path!);
        if (bytes.isNotEmpty) {
          final cacheFile = File('${cacheDir.path}/${song.path!.hashCode}.jpg');
          await cacheFile.writeAsBytes(bytes);
          song.coverUrl = cacheFile.path;
          song.hasCover = true;
        }
      } catch (_) {}
    }
  }

  /// iOS 平台通道封面缓存
  static Future<void> _cacheIOSCover(Song song, Directory cacheDir) async {
    final pid = MediaStoreChannel.parsePersistentId(song.id);
    if (pid == null) return;
    try {
      final bytes = await MediaStoreChannel.getArtwork(pid);
      if (bytes != null && bytes.isNotEmpty) {
        final cacheFile = File('${cacheDir.path}/${song.path!.hashCode}.jpg');
        await cacheFile.writeAsBytes(bytes);
        song.coverUrl = cacheFile.path;
        song.hasCover = true;
      }
    } catch (_) {}
  }
}
