import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

class Song {
  final String id;
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
    this.hasCover = false,
  });

  String get formattedDuration {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class Album {
  final String id;
  final String title;
  final String artist;
  final int year;
  final List<Song> songs;
  final Color dominantColor;

  Duration get totalDuration =>
      songs.fold(Duration.zero, (sum, s) => sum + s.duration);

  String formattedDurationOf(AppLocalizations l10n) {
    final m = totalDuration.inMinutes;
    return l10n.minuteFormat(m);
  }

  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.songs,
    required this.dominantColor,
  });
}
