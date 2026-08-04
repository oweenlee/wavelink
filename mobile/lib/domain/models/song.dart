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
