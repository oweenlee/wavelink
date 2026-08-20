import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/services/library.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wavelink_scan_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  File writeFile(String name) {
    final f = File('${tmp.path}/$name');
    f.createSync(recursive: true);
    return f;
  }

  group('scanFolder', () {
    test('scans recursively and filters by audio extension', () async {
      writeFile('ArtistA - Song1.flac');
      writeFile('ArtistB - Song2.mp3');
      writeFile('nested/ArtistC - Song3.wav');
      writeFile('readme.txt');
      writeFile('cover.png');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.length, 3);
    });

    test('parses "Artist - Title" naming', () async {
      writeFile('Foo Bar - Baz Song.flac');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.single.artist, 'Foo Bar');
      expect(tracks.single.title, 'Baz Song');
    });

    test('falls back to filename as title with unknown artist', () async {
      writeFile('just_a_name.flac');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.single.title, 'just_a_name');
      expect(tracks.single.artist, '未知艺人');
    });

    test('finds sibling .lrc lyrics file', () async {
      writeFile('A - B.flac');
      writeFile('A - B.lrc');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.single.lyricsPath, isNotNull);
      expect(tracks.single.lyricsPath, endsWith('.lrc'));
    });

    test('missing directory returns empty list', () async {
      final tracks = await scanFolder('/nonexistent/path/xyz');
      expect(tracks, isEmpty);
    });

    test('sorts by artist then title', () async {
      writeFile('B - 2.flac');
      writeFile('A - 2.flac');
      writeFile('A - 1.flac');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.map((t) => t.artist).toList(), ['A', 'A', 'B']);
      expect(tracks.map((t) => t.title).toList(), ['1', '2', '2']);
    });

    test('.cue 文件本身不会作为曲目入库', () async {
      writeFile('A - B.flac');
      writeFile('album.cue');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.length, 1);
      expect(tracks.single.title, 'B');
    });

    test('引擎不可用时 cue 静默降级：镜像音频仍按普通曲目入库', () async {
      // 未加载 dylib（单测环境）：parseCueBytes 抛异常 → 跳过该 cue，
      // 不做镜像排除，音频文件照常扫描（不崩、不丢曲）。
      writeFile('ArtistA - Song1.wav');
      writeFile('album.cue');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.length, 1);
      expect(tracks.single.isCueTrack, isFalse);
      expect(tracks.single.filePath, endsWith('ArtistA - Song1.wav'));
    });
  });
}
