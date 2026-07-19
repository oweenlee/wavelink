import 'package:flutter/material.dart';
import 'package:wavelink_mobile/l10n/app_localizations.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Color dominantColor;
  final bool hasLyrics;
  final int? bpm;
  final String? key;
  final String? coverUrl;
  final String? path;
  final bool hasCover;

  const Song({
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
