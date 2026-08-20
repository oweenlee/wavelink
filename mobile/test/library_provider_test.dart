import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:wavelink_mobile/data/services/library_cache_service.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/domain/models/song.dart';
import 'package:wavelink_mobile/ui/core/providers/repositories.dart';
import 'package:wavelink_mobile/ui/features/library/view_models/library_provider.dart';
import 'helpers/mock_repositories.dart';
import 'package:checks/checks.dart';

/// 独立 Documents 目录，防止与 library_cache_service_test 共用同一 DB 文件
const docs = '/tmp/lp_test';

/// NAS 索引歌（无本地文件，走 smbPath 下载通路）
Song _nasSong(String id) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  smbPath: 'Music/$id.flac',
);

/// 本地歌（path 存在，不触发远端下载）
Song _localSong(String id) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  path: '/tmp/$id.flac',
);

/// WebDAV 远端索引歌（davPath）
Song _webdavSong(String id) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  davPath: 'Music/$id.flac',
);

/// Subsonic 流式歌（streamUrl）
Song _subsonicSong(String id) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  streamUrl: 'https://sub.example/rest/stream?id=$id',
);

/// Apple Music 同步歌（ipod-library:// 路径）
Song _appleMusicSong(String id) => Song(
  id: id,
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  path: 'ipod-library://item/item$id?id=$id',
);

/// 文件导入歌（id 前缀 imp_）
Song _importedSong(String id) => Song(
  id: 'imp_$id',
  title: id,
  artist: 'artist',
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  path: '/tmp/$id.flac',
);

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
    for (final id in ['local1', 'local2']) {
      File('/tmp/$id.flac').createSync();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => docs,
        );
    // 关闭并删除本测试专属 DB，避免与其他测试文件共享 /tmp/library.db
    await LibraryCacheService.close();
    final dbFile = File('$docs/library.db');
    if (await dbFile.exists()) await dbFile.delete();
    await LibraryCacheService.init();
  });

  /// 等待 notifier 触发的异步落库（saveFavorites 是 fire-and-forget）
  Future<void> waitFavorites(Set<String> expected) async {
    for (var i = 0; i < 100; i++) {
      if (setEquals(await LibraryCacheService.loadFavorites(), expected)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('收藏未在预期时间内落库为 $expected');
  }

  ProviderContainer buildContainer({
    List<Song>? songs,
  }) {
    final repo = MockSongRepository()..songsToReturn = songs ?? [];
    final container = ProviderContainer(
      overrides: [
        songRepositoryProvider.overrideWith((_) => repo),
        preferencesRepositoryProvider.overrideWith(
          (_) => PreferencesRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  LibraryNotifier seed(ProviderContainer container, List<Song> songs) {
    final notifier = container.read(libraryProvider.notifier);
    notifier.restoreCachedSongs(songs);
    return notifier;
  }

  group('LibraryNotifier 收藏', () {
    test('toggleFavoriteFor 添加与移除', () {
      final n = seed(buildContainer(), [_nasSong('a'), _nasSong('b')]);
      n.toggleFavoriteFor(_nasSong('a'));
      check(n.state.favoriteIds).deepEquals({'a'});
      n.toggleFavoriteFor(_nasSong('a'));
      check(n.state.favoriteIds).isEmpty();
    });

    test('toggleFavoriteFor null 安全', () {
      final n = seed(buildContainer(), []);
      n.toggleFavoriteFor(null);
      check(n.state.favoriteIds).isEmpty();
    });

    test('setFavorite 显式设置 true/false', () {
      final n = seed(buildContainer(), [_nasSong('a')]);
      n.setFavorite('a', true);
      check(n.state.favoriteIds).deepEquals({'a'});
      n.setFavorite('a', false);
      check(n.state.favoriteIds).isEmpty();
    });

    test('收藏持久化到 SQLite', () async {
      // 先清空库内残留，保证断言从干净状态开始
      await LibraryCacheService.saveFavorites({});
      final n = seed(buildContainer(), [_nasSong('a')]);
      n.setFavorite('a', true);
      await waitFavorites({'a'});
      n.setFavorite('a', false);
      await waitFavorites({});
    });

    test('isSongFavorite / isFavorite', () {
      final n = seed(buildContainer(), [_nasSong('a')]);
      n.setFavorite('a', true);
      check(n.state.isSongFavorite('a')).isTrue();
      check(n.isFavorite(_nasSong('a'))).isTrue();
      check(n.isFavorite(_nasSong('b'))).isFalse();
      check(n.isFavorite(null)).isFalse();
    });

    test('favoriteSongs 只返回收藏的歌曲', () {
      final n = seed(buildContainer(), [_nasSong('a'), _nasSong('b')]);
      n.setFavorite('a', true);
      final favs = n.favoriteSongs();
      check(favs.length).equals(1);
      check(favs.single.id).equals('a');
    });
  });

  group('LibraryNotifier 曲库过滤', () {
    test('allSongs 按各来源开关过滤（六种来源逐一验证）', () async {
      final p = PreferencesService.instance;
      final songs = [
        _nasSong('nas'),
        _webdavSong('dav'),
        _subsonicSong('sub'),
        _appleMusicSong('am'),
        _importedSong('imp'),
        _localSong('loc'),
      ];
      final toggles = <(String, Future<void> Function(bool))>[
        ('nas', p.setShowNas),
        ('dav', p.setShowWebdav),
        ('sub', p.setShowSubsonic),
        ('am', p.setShowAppleMusic),
        ('imp_imp', p.setShowImported),
        ('loc', p.setShowLocal),
      ];
      for (final (hiddenId, setter) in toggles) {
        await setter(false);
        final n = seed(buildContainer(), songs);
        final ids = n.state.allSongs.map((s) => s.id).toList();
        check(ids)
            .deepEquals(songs.map((s) => s.id).where((id) => id != hiddenId).toList());
        await setter(true); // 复位，避免影响后续来源
      }
    });

    test('restoreCachedSongs 注入后全部可见（默认全开）', () {
      final n = seed(buildContainer(), [_nasSong('a'), _localSong('b')]);
      final ids = n.state.allSongs.map((s) => s.id).toList();
      check(ids).deepEquals(['a', 'b']);
    });
  });
}