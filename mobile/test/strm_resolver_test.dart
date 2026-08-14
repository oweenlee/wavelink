import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/strm_resolver.dart';
import 'package:wavelink_mobile/domain/models/song.dart';

/// 测试用 Song：可变字段带初始值，便于验证回填。
Song TestSong() => Song(
      id: 'test',
      title: '旧标题',
      artist: 'Unknown Artist',
      album: 'NAS Music',
      duration: Duration.zero,
      dominantColor: const Color(0xFF000000),
      durationEstimated: true,
    );

void main() {
  group('parseStrmContent', () {
    test('单行完整 URL（带扩展名）→ http', () {
      final t = parseStrmContent(
        'http://127.0.0.1:8080/music/song.flac\n',
        fromWebdav: false,
        strmPath: 'library/01.strm',
      );
      expect(t, isNotNull);
      expect(t!.kind, 'http');
      expect(t.path, 'http://127.0.0.1:8080/music/song.flac');
    });

    test('无扩展名 URL（电台流）→ stream', () {
      final t = parseStrmContent(
        'https://ice1.somafm.com/groovesalad-128-mp3',
        fromWebdav: false,
        strmPath: 'library/01.strm',
      );
      expect(t, isNotNull);
      expect(t!.kind, 'stream');
    });

    test('相对路径：相对 strm 所在目录', () {
      final t = parseStrmContent(
        'Artist/Album/song.flac',
        fromWebdav: false,
        strmPath: 'Music/Playlist/01.strm',
      );
      expect(t, isNotNull);
      expect(t!.kind, 'smb');
      expect(t.path, 'Music/Playlist/Artist/Album/song.flac');
    });

    test('相对路径以 / 开头：相对库根', () {
      final t = parseStrmContent(
        '/Music/song.flac',
        fromWebdav: true,
        strmPath: 'Playlist/01.strm',
      );
      expect(t, isNotNull);
      expect(t!.kind, 'dav');
      expect(t.path, 'Music/song.flac');
    });

    test('../ 上溯 + BOM 规范化', () {
      final t = parseStrmContent(
        '\uFEFF../Media/song.flac\n',
        fromWebdav: false,
        strmPath: 'Music/Playlist/01.strm',
      );
      expect(t, isNotNull);
      expect(t!.path, 'Music/Media/song.flac');
    });

    test('#EXTINF 信息行：标题与时长（Kodi 风格）', () {
      final t = parseStrmContent(
        '#EXTINF:245,周杰伦 - 晴天\nreal.flac\n',
        fromWebdav: false,
        strmPath: 'library/05.strm',
      );
      expect(t, isNotNull);
      expect(t!.kind, 'smb');
      expect(t.path, 'library/real.flac');
      expect(t.extInfTitle, '周杰伦 - 晴天');
      expect(t.extInfSecs, 245);
    });

    test('#EXTINF 非法（0 时长/空标题）不阻断目标解析', () {
      final t = parseStrmContent(
        '#EXTINF:0,\nreal.flac\n',
        fromWebdav: false,
        strmPath: 'library/05.strm',
      );
      expect(t, isNotNull);
      expect(t!.path, 'library/real.flac');
      expect(t.extInfTitle, isNull);
      expect(t.extInfSecs, isNull);
    });

    test('目标非音频扩展名 → null', () {
      expect(
        parseStrmContent('movie.mkv', fromWebdav: false, strmPath: 'x.strm'),
        isNull,
      );
      expect(
        parseStrmContent(
          'http://x.com/a.txt',
          fromWebdav: false,
          strmPath: 'x.strm',
        ),
        isNull,
      );
    });

    test('空内容 / 纯注释 → null', () {
      expect(
        parseStrmContent('', fromWebdav: false, strmPath: 'x.strm'),
        isNull,
      );
      expect(
        parseStrmContent('# only comment\n', fromWebdav: false, strmPath: 'x.strm'),
        isNull,
      );
    });

    test('多行 strm 只取首行有效内容', () {
      final t = parseStrmContent(
        'first.flac\nsecond.flac\n',
        fromWebdav: false,
        strmPath: 'library/01.strm',
      );
      expect(t, isNotNull);
      expect(t!.path, 'library/first.flac');
    });
  });

  group('applyExtInfToSong', () {
    test('标题按 Artist - Title 拆分回填，时长覆盖估算', () {
      final song = TestSong();
      final changed = applyExtInfToSong(
        song,
        const StrmTarget(
          kind: 'http',
          path: 'http://x/1.flac',
          extInfTitle: '周杰伦 - 晴天',
          extInfSecs: 245,
        ),
      );
      expect(changed, isTrue);
      expect(song.title, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.duration, const Duration(seconds: 245));
      expect(song.durationEstimated, isFalse);
    });

    test('无信息行 → 无回填', () {
      final song = TestSong();
      final changed = applyExtInfToSong(
        song,
        const StrmTarget(kind: 'http', path: 'http://x/1.flac'),
      );
      expect(changed, isFalse);
      expect(song.title, '旧标题');
    });
  });
}
