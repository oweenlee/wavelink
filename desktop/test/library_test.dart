import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
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

    test('empty folder returns empty list without throwing', () async {
      // 回归：空目录（或全为 cue 镜像被排除）曾因
      // _metadataConcurrency.clamp(1, 0) 抛 ArgumentError 导致扫描崩溃。
      final tracks = await scanFolder(tmp.path);
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

    test('onBatch 增量回调：分批下发且不重不漏（大文件夹首屏不等待）', () async {
      // 回归：600 首文件夹曾等全部解析完才一次性出现列表（点击后数秒空白）。
      // 现每攒满一批（32 首）就回调一次，调用方据此边扫边入库。
      for (var i = 0; i < 70; i++) {
        writeFile('A${i % 7} - Song${i.toString().padLeft(3, '0')}.flac');
      }
      final batches = <List<Track>>[];
      final tracks = await scanFolder(tmp.path, onBatch: batches.add);

      final collected = batches.expand((b) => b).toList();
      expect(collected.length, 70, reason: '批次总和应等于全部曲目');
      expect(collected.map((t) => t.id).toSet().length, 70,
          reason: '跨批次不得重复');
      expect(batches.length, greaterThanOrEqualTo(3),
          reason: '70 首 / 批 32 → 至少 3 批（含尾部余数批次）');
      expect(tracks.length, 70);
      expect(collected.map((t) => t.id).toSet(),
          tracks.map((t) => t.id).toSet());
    });

    test('onBatch 为 null 时行为与旧版一致（兼容现有调用方）', () async {
      writeFile('A - 1.flac');
      writeFile('B - 2.flac');
      final tracks = await scanFolder(tmp.path);
      expect(tracks.length, 2);
    });
  });
}
