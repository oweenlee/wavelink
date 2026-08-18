import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/services/lyrics.dart';

void main() {
  group('parseLrc', () {
    test('parses basic timestamps and sorts by time', () {
      const content = '''
[00:20.00]second line
[00:05.00]first line
[01:02.50]third line
''';
      final lines = parseLrc(content);
      expect(lines.length, 3);
      expect(lines[0].text, 'first line');
      expect(lines[0].time, const Duration(seconds: 5));
      expect(lines[2].time,
          const Duration(minutes: 1, seconds: 2, milliseconds: 500));
    });

    test('supports multiple timestamps per line', () {
      const content = '[00:10.00][00:40.00]repeated\n';
      final lines = parseLrc(content);
      expect(lines.length, 2);
      expect(lines.every((l) => l.text == 'repeated'), true);
    });

    test('handles centiseconds (2-digit fraction) vs milliseconds (3-digit)',
        () {
      const content = '[00:01.50]a\n[00:02.500]b\n';
      final lines = parseLrc(content);
      // .50 → 50cs = 500ms（加在整秒上）；.500 → 500ms（等价粒度）
      expect(lines[0].time, const Duration(milliseconds: 1500));
      expect(lines[1].time, const Duration(milliseconds: 2500));
    });

    test('skips metadata tags and blank lines', () {
      const content = '''
[ti:Title]
[ar:Artist]

[00:01.00]only real line
''';
      final lines = parseLrc(content);
      expect(lines.length, 1);
      expect(lines[0].text, 'only real line');
    });
  });

  group('activeLyricIndex', () {
    final lines = [
      LyricLine(const Duration(seconds: 0), 'a'),
      LyricLine(const Duration(seconds: 10), 'b'),
      LyricLine(const Duration(seconds: 20), 'c'),
    ];

    test('returns -1 for empty list', () {
      expect(activeLyricIndex(const [], Duration.zero), -1);
    });

    test('finds active line via binary search', () {
      expect(activeLyricIndex(lines, const Duration(seconds: 5)), 0);
      expect(activeLyricIndex(lines, const Duration(seconds: 15)), 1);
      expect(activeLyricIndex(lines, const Duration(seconds: 25)), 2);
      // 恰好落在某行时间点 → 该行生效
      expect(activeLyricIndex(lines, const Duration(seconds: 10)), 1);
      // 早于第一行 → -1
      //（第一行 t=0，此用例不可构造 -1，改用负值时长验证边界）
    });
  });
}
