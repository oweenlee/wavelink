import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

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
  String? lyricsPath;
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
    this.lyricsPath,
    this.hasCover = false,
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
        'lyricsPath': lyricsPath,
        'hasCover': hasCover,
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
        lyricsPath: json['lyricsPath'] as String?,
        hasCover: json['hasCover'] as bool? ?? false,
      );

  String get formattedDuration {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 格式标签，如 "FLAC"、"DSD"、"MP3 320"、"WAV"
  /// 从文件路径扩展名推断，用于 SongTile 的格式 pill
  String? get formatInfo {
    if (path == null) return null;
    final ext = path!.split('.').last.toUpperCase();
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
    if (path == null) return false;
    final ext = path!.split('.').last.toUpperCase();
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
