import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/library_cache_service.dart';
import 'package:wavelink_mobile/domain/models/song.dart';

/// 曲库 SQLite 持久化的「存取往返 + 相对路径 + 旧 JSON 迁移」验证。
/// 在 macOS 宿主上跑 flutter test：LibraryCacheService.init 检测到
/// 非移动平台自动启用 sqflite_common_ffi，真实落盘到 /tmp（path_provider
/// mock 的目标目录）。
const docs = '/tmp';

/// coverUrl/lyricsPath 用绝对路径模拟真实数据（封面缓存目录在 Documents 下）
Song _song(String id, {String? path, String? streamUrl, String? smbPath}) =>
    Song(
      id: id,
      title: '标题$id',
      artist: '艺术家',
      album: '专辑',
      duration: const Duration(minutes: 3, seconds: 5),
      dominantColor: const Color(0xFF123456),
      hasLyrics: true,
      bpm: 120,
      key: 'Am',
      coverUrl: '$docs/covers/$id.jpg',
      path: path,
      streamUrl: streamUrl,
      smbPath: smbPath,
      strmFromWebdav: true,
      targetUri: 'nas/music/$id.flac',
      targetKind: 'smb',
      lyricsPath: '$docs/lyrics/$id.lrc',
      hasCover: true,
      durationEstimated: true,
    );

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => docs,
        );
    await LibraryCacheService.close();
    for (final f in ['/tmp/library.db', '/tmp/.library_cache.json']) {
      if (await File(f).exists()) await File(f).delete();
    }
  });

  tearDown(() async {
    await LibraryCacheService.close();
    for (final f in ['/tmp/library.db', '/tmp/.library_cache.json']) {
      if (await File(f).exists()) await File(f).delete();
    }
  });

  test('saveSongs → loadSongs 往返还原全部字段', () async {
    await LibraryCacheService.saveSongs([
      _song('a'),
      _song('b', path: '$docs/music/b.flac'),
    ]);
    final loaded = await LibraryCacheService.loadSongs();
    check(loaded.length).equals(2);

    final a = loaded.firstWhere((s) => s.id == 'a');
    check(a.title).equals('标题a');
    check(a.artist).equals('艺术家');
    check(a.album).equals('专辑');
    check(a.duration).equals(const Duration(minutes: 3, seconds: 5));
    check(a.dominantColor.toARGB32()).equals(0xFF123456);
    check(a.hasLyrics).isTrue();
    check(a.bpm).equals(120);
    check(a.key).equals('Am');
    check(a.coverUrl).equals('$docs/covers/a.jpg');
    check(a.hasCover).isTrue();
    check(a.durationEstimated).isTrue();
    check(a.smbPath).isNull();
    check(a.targetUri).equals('nas/music/a.flac');
    check(a.targetKind).equals('smb');
    check(a.strmFromWebdav).isTrue();
  });

  test('沙盒内 path/coverUrl/lyricsPath 存相对路径，读回还原绝对路径', () async {
    await LibraryCacheService.saveSongs([
      _song('a', path: '$docs/Music/a.flac'),
    ]);
    final loaded = await LibraryCacheService.loadSongs();
    final a = loaded.single;
    check(a.path).equals('$docs/Music/a.flac');
    check(a.coverUrl).equals('$docs/covers/a.jpg');
    check(a.lyricsPath).equals('$docs/lyrics/a.lrc');

    // 数据库里实际存的是相对路径（免疫 iOS 容器目录变化）
    final raw = await File('/tmp/library.db').readAsBytes();
    final content = String.fromCharCodes(raw);
    check(content.contains('/Music/a.flac')).isFalse();
    check(content.contains('Music/a.flac')).isTrue();
    check(content.contains('/covers/a.jpg')).isFalse();
    check(content.contains('covers/a.jpg')).isTrue();
  });

  test('沙盒外绝对路径（ipod-library://）原样存储', () async {
    await LibraryCacheService.saveSongs([
      _song('apple', path: 'ipod-library://item/1'),
    ]);
    final loaded = await LibraryCacheService.loadSongs();
    check(loaded.single.path).equals('ipod-library://item/1');
  });

  test('saveSongs 全量替换：第二次保存清空上一次', () async {
    await LibraryCacheService.saveSongs([_song('a'), _song('b')]);
    await LibraryCacheService.saveSongs([_song('c')]);
    final ids = (await LibraryCacheService.loadSongs()).map((s) => s.id);
    check(ids).deepEquals(['c']);
  });

  test('saveSongs([]) 清空曲库', () async {
    await LibraryCacheService.saveSongs([_song('a')]);
    await LibraryCacheService.saveSongs([]);
    check(await LibraryCacheService.loadSongs()).isEmpty();
  });

  test('连续 saveSongs 覆盖式合并：只落盘最后一次', () async {
    await LibraryCacheService.close();
    final before = LibraryCacheService.persistCount;
    Future<void>? last;
    for (var i = 0; i < 10; i++) {
      last = LibraryCacheService.saveSongs([_song('s$i')]);
    }
    await last;
    final ids = (await LibraryCacheService.loadSongs()).map((s) => s.id);
    check(ids).deepEquals(['s9']);
    check(LibraryCacheService.persistCount - before).isLessThan(3);
  });

  test('旧 JSON 缓存首次打开自动迁移并删除', () async {
    final json = [
      _song('j1', path: '$docs/Music/j1.flac').toJson(),
      _song('j2').toJson(),
    ];
    await File('$docs/.library_cache.json')
        .writeAsString(jsonEncode(json));

    final loaded = await LibraryCacheService.loadSongs();
    check(loaded.length).equals(2);
    check(loaded.first.path).equals('$docs/Music/j1.flac');
    check(await File('$docs/.library_cache.json').exists()).isFalse();
  });

  test('库内已有数据时跳过 JSON 迁移', () async {
    await LibraryCacheService.saveSongs([_song('db1')]);
    await File('$docs/.library_cache.json')
        .writeAsString(jsonEncode([_song('old').toJson()]));

    final loaded = await LibraryCacheService.loadSongs();
    check(loaded.map((s) => s.id)).deepEquals(['db1']);
    check(await File('$docs/.library_cache.json').exists()).isTrue();
  });
}