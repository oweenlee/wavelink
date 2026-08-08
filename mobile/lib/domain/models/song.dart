import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// 歌曲来源（用于列表行来源图标）
enum SongSource { nas, subsonic, appleMusic, imported, local }

class Song {
  String id;
  String title;
  String artist;
  String album;
  Duration duration;
  final Color dominantColor;
  bool hasLyrics;
  int? bpm;
  String? key;
  String? coverUrl;
  final String? path;
  /// HTTP(S) 流式播放 URL（Subsonic 等远程源），为空表示本地文件。
  /// 如果设置了此字段，播放前需先下载到本地临时缓存。
  final String? streamUrl;
  /// SMB 共享内相对路径（离线模式为 null 时歌曲尚未下载到本地）。
  /// 设置了此字段表示文件在远端共享，播放时先按需下载到本地缓存。
  final String? smbPath;
  String? lyricsPath;
  /// 时长是否为估算值（NAS 等无法读取元数据时按文件大小估算）。
  /// 估算值不参与曲库列表显示；播放时引擎探测到真实时长后回填并置 false。
  bool durationEstimated;
  bool hasCover;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.dominantColor,
    this.hasLyrics = false,
    this.bpm,
    this.key,
    this.coverUrl,
    this.path,
    this.streamUrl,
    this.smbPath,
    this.lyricsPath,
    this.hasCover = false,
    this.durationEstimated = false,
  });

  /// 序列化为 JSON（轻量持久化：曲库缓存）
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': duration.inMilliseconds,
        'color': dominantColor.toARGB32(),
        'hasLyrics': hasLyrics,
        'bpm': bpm,
        'key': key,
        'coverUrl': coverUrl,
        'path': path,
        'streamUrl': streamUrl,
        'smbPath': smbPath,
        'lyricsPath': lyricsPath,
        'hasCover': hasCover,
        'durationEstimated': durationEstimated,
      };

  /// 从 JSON 还原（与 [toJson] 对称）
  factory Song.fromJson(Map<String, dynamic> json) => Song(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String,
        duration: Duration(milliseconds: json['durationMs'] as int),
        dominantColor: Color(json['color'] as int),
        hasLyrics: json['hasLyrics'] as bool? ?? false,
        bpm: json['bpm'] as int?,
        key: json['key'] as String?,
        coverUrl: json['coverUrl'] as String?,
        path: json['path'] as String?,
        streamUrl: json['streamUrl'] as String?,
        smbPath: json['smbPath'] as String?,
        lyricsPath: json['lyricsPath'] as String?,
        hasCover: json['hasCover'] as bool? ?? false,
        durationEstimated: json['durationEstimated'] as bool? ?? false,
      );

  String get formattedDuration {
    if (durationEstimated) return '--:--';
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 来源判断优先级：NAS > 流式(Subsonic) > Apple Music 同步 > 文件导入 > 本地媒体库
  SongSource get source {
    if (smbPath != null && smbPath!.isNotEmpty) return SongSource.nas;
    if (streamUrl != null && streamUrl!.isNotEmpty) return SongSource.subsonic;
    if (path != null && path!.startsWith('ipod-library://')) {
      return SongSource.appleMusic;
    }
    if (id.startsWith('imp_')) return SongSource.imported;
    return SongSource.local;
  }

  /// 艺术家显示名：占位文案视为解析不到，返回 null（UI 不显示）
  String? get displayArtist {
    final a = artist.trim();
    if (a.isEmpty) return null;
    const placeholders = {'Unknown Artist', '未知艺术家'};
    if (placeholders.contains(a)) return null;
    return a;
  }

  /// 专辑显示名：占位文案（NAS/导入降级）视为解析不到，返回 null（UI 不显示专辑段）
  String? get displayAlbum {
    final a = album.trim();
    if (a.isEmpty) return null;
    const placeholders = {'NAS Music', 'Imported Music', '导入的音乐', 'Unknown Album'};
    if (placeholders.contains(a)) return null;
    return a;
  }

  /// 副标题行：艺术家 · 专辑。解析不到的部分不显示，都解析不到返回空串（UI 只留来源图标）
  String get artistAlbumLine {
    final a = displayArtist;
    final al = displayAlbum;
    if (a != null && al != null) return '$a · $al';
    if (a != null) return a;
    if (al != null) return al;
    return '';
  }

  /// 格式标签，如 "FLAC"、"DSD"、"MP3 320"、"WAV"
  /// 从文件路径扩展名推断，用于 SongTile 的格式 pill。
  /// 本地文件看 [path]；NAS 未下载（仅索引）看 [smbPath]；流式源看 [streamUrl]（取 URL path 去 query）。
  String? get formatInfo {
    final src = path ?? smbPath ?? streamUrl;
    if (src == null) return null;
    final ext = src.split('?').first.split('.').last.toUpperCase();
    switch (ext) {
      case 'FLAC':
        return 'FLAC';
      case 'WAV':
        return 'WAV';
      case 'DSF':
      case 'DFF':
        return 'DSD';
      case 'MP3':
        return 'MP3';
      case 'AAC':
      case 'M4A':
        return 'AAC';
      case 'OGG':
        return 'OGG';
      case 'OPUS':
        return 'OPUS';
      case 'APE':
        return 'APE';
      case 'WV':
      case 'WAVPACK':
        return 'WV';
      case 'AIFF':
      case 'AIF':
        return 'AIFF';
      default:
        return ext.isEmpty ? null : ext;
    }
  }

  /// 是否为无损格式（用于格式 pill 高亮）
  bool get isLossless {
    final src = path ?? smbPath ?? streamUrl;
    if (src == null) return false;
    final ext = src.split('?').first.split('.').last.toUpperCase();
    return ['FLAC', 'WAV', 'DSF', 'DFF', 'AIFF', 'AIF', 'APE', 'WV'].contains(ext);
  }
}

class Album {
  final String id;
  final String title;
  final String artist;
  final int year;
  final List<Song> songs;
  final Color dominantColor;

  Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.songs,
    required this.dominantColor,
  });

  Duration get totalDuration =>
      songs.fold(Duration.zero, (sum, s) => sum + s.duration);

  String formattedDurationOf(AppLocalizations l10n) {
    final m = totalDuration.inMinutes;
    return l10n.minuteFormat(m);
  }
}
