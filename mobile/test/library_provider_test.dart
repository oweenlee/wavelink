import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/domain/models/song.dart';
import 'package:wavelink_mobile/ui/core/providers/repositories.dart';
import 'package:wavelink_mobile/ui/features/library/view_models/library_provider.dart';
import 'helpers/mock_repositories.dart';
import 'package:checks/checks.dart';

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
          (call) async => '/tmp',
        );
  });

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

    test('收藏持久化到 PreferencesService', () async {
      final n = seed(buildContainer(), [_nasSong('a')]);
      n.setFavorite('a', true);
      check(PreferencesService.instance.favorites).deepEquals({'a'});
      n.setFavorite('a', false);
      check(PreferencesService.instance.favorites).isEmpty();
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
    test('allSongs 按来源开关过滤（NAS 关闭时隐藏）', () async {
      await PreferencesService.instance.setShowNas(false);
      final n = seed(buildContainer(), [_nasSong('a'), _localSong('b')]);
      final ids = n.state.allSongs.map((s) => s.id).toList();
      check(ids).deepEquals(['b']);
    });

    test('restoreCachedSongs 注入后全部可见（默认全开）', () {
      final n = seed(buildContainer(), [_nasSong('a'), _localSong('b')]);
      final ids = n.state.allSongs.map((s) => s.id).toList();
      check(ids).deepEquals(['a', 'b']);
    });
  });

  group('LibraryNotifier 收藏离线下载', () {
    test('收藏本地歌不触发远端下载且不崩溃', () async {
      final n = seed(buildContainer(), [_localSong('local1')]);
      n.setFavorite('local1', true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      check(n.state.favoriteIds).deepEquals({'local1'});
    });

    test('收藏 NAS 歌触发下载：无 NAS 配置时静默失败不崩溃', () async {
      // 默认无 NAS host 配置，downloadToLocal 在 ensureReady 处快速失败返回
      final n = seed(buildContainer(), [_nasSong('a')]);
      n.setFavorite('a', true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      check(n.state.favoriteIds).deepEquals({'a'});
    });
  });
}