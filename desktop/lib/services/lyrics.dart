import 'dart:io';
import 'package:flutter/foundation.dart';

class LyricLine {
  final Duration time;
  final String text;

  LyricLine(this.time, this.text);
}

/// Parse a standard .lrc file into time-sorted lyric lines.
/// Supports multiple timestamps per line, e.g. `[00:12.34][00:50.00]text`.
List<LyricLine> parseLrc(String content) {
  final timeTag = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  final Map<Duration, String> map = {};

  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final matches = timeTag.allMatches(line);
    if (matches.isEmpty) continue;

    final text = line.replaceAll(timeTag, '').trim();
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      final fracRaw = m.group(3) ?? '0';
      // group(3) may be milliseconds (3 digits) or centiseconds (2 digits)
      final frac = int.parse(fracRaw.padRight(3, '0').substring(0, 3));
      final time = Duration(minutes: min, seconds: sec, milliseconds: frac);
      map[time] = text;
    }
  }

  final lines = map.entries
      .map((e) => LyricLine(e.key, e.value))
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// Load and parse the .lrc sibling of a track, if present.
Future<List<LyricLine>> loadLyrics(String? lyricsPath) async {
  if (lyricsPath == null) return const [];
  try {
    final file = File(lyricsPath);
    if (!await file.exists()) return const [];
    final content = await file.readAsString();
    return parseLrc(content);
  } catch (e) {
    debugPrint('loadLyrics error: $e');
    return const [];
  }
}

/// Find the index of the lyric line active at [position].
int activeLyricIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty) return -1;
  int lo = 0, hi = lines.length - 1, res = -1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    if (lines[mid].time <= position) {
      res = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return res;
}
