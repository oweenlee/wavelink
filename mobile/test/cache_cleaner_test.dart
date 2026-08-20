import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/cache_cleaner.dart';
import 'package:wavelink_mobile/domain/models/song.dart';

/// 独立 Documents 目录，path_provider mock 指向这里
const docs = '/tmp/cc_test';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory(docs);
    if (await dir.exists()) await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => docs,
        );
  });

  Future<void> write(String relPath, int bytes) async {
    final f = File('$docs/$relPath');
    await f.create(recursive: true);
    await f.writeAsBytes(List.filled(bytes, 1));
  }

  Song song({
    String? path,
    String? coverUrl,
    String? lyricsPath,
    String? smbPath,
    String? davPath,
  }) =>
      Song(
        id: 's1',
        title: 't',
        artist: 'a',
        album: 'al',
        duration: const Duration(seconds: 1),
        dominantColor: const Color(0xFFFF0000),
        path: path,
        coverUrl: coverUrl,
        lyricsPath: lyricsPath,
        smbPath: smbPath,
        davPath: davPath,
      );

  group('CacheCleaner', () {
    test('computeCacheBytes 统计四类缓存目录', () async {
      await write('.covers/a.jpg', 100);
      await write('.smb_cache/b.flac', 200);
      await write('.webdav_cache/c.flac', 300);
      await write('.lrc_cache/d.lrc', 50);

      final bytes = await CacheCleaner.computeCacheBytes();
      check(bytes).equals(650);
    });

    test('collectReferencedFiles 收集歌曲引用的全部沙盒文件', () async {
      final s = song(
        path: '$docs/.smb_cache/keep.flac',
        coverUrl: '$docs/.covers/keep.jpg',
        lyricsPath: '$docs/.lrc_cache/keep.lrc',
        smbPath: 'Music/s1.flac',
        davPath: 'dav/albums/s1.flac',
      );

      final refs = await CacheCleaner.collectReferencedFiles([s]);
      check(refs).contains(s.path!);
      check(refs).contains(s.coverUrl!);
      check(refs).contains(s.lyricsPath!);
      // smbPath → NAS 歌词本地缓存；davPath → WebDAV 下载缓存
      check(refs).contains('$docs/.lrc_cache/${s.smbPath.hashCode}.lrc');
      check(refs).contains(
        '$docs/.webdav_cache/${s.davPath!.hashCode}_${s.davPath!.split('/').last}',
      );
    });

    test('clearUnreferencedCache 仅删除曲库无引用的文件', () async {
      final s = song(
        path: '$docs/.smb_cache/keep.flac',
        coverUrl: '$docs/.covers/keep.jpg',
        lyricsPath: '$docs/.lrc_cache/keep.lrc',
        smbPath: 'Music/s1.flac',
      );
      await write('.covers/keep.jpg', 10);
      await write('.covers/orphan.jpg', 20);
      await write('.smb_cache/keep.flac', 10);
      await write('.smb_cache/orphan.flac', 30);
      await write('.webdav_cache/orphan.flac', 40);
      final lrcPath = '$docs/.lrc_cache/${s.smbPath.hashCode}.lrc';
      await write(lrcPath.substring(docs.length + 1), 10);
      await write('.lrc_cache/orphan.lrc', 5);

      final refs = await CacheCleaner.collectReferencedFiles([s]);
      final freed = await CacheCleaner.clearUnreferencedCache(refs);

      // 释放 4 个孤儿文件：20+30+40+5
      check(freed).equals(20 + 30 + 40 + 5);
      check(File(s.path!).existsSync()).isTrue();
      check(File(s.coverUrl!).existsSync()).isTrue();
      check(File(lrcPath).existsSync()).isTrue();
      check(File('$docs/.covers/orphan.jpg').existsSync()).isFalse();
      check(File('$docs/.smb_cache/orphan.flac').existsSync()).isFalse();
      check(File('$docs/.webdav_cache/orphan.flac').existsSync()).isFalse();
      check(File('$docs/.lrc_cache/orphan.lrc').existsSync()).isFalse();
    });
  });
}