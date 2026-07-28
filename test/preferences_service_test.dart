import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
  });

  group('PreferencesService 持久化', () {
    test('音量读写', () async {
      final prefs = PreferencesService.instance;
      expect(prefs.volume, 0.8);
      await prefs.setVolume(0.5);
      expect(prefs.volume, 0.5);
    });

    test('循环模式读写', () async {
      final prefs = PreferencesService.instance;
      expect(prefs.loopMode, 'list');
      await prefs.setLoopMode('single');
      expect(prefs.loopMode, 'single');
    });

    test('随机开关读写', () async {
      final prefs = PreferencesService.instance;
      expect(prefs.shuffle, isFalse);
      await prefs.setShuffle(true);
      expect(prefs.shuffle, isTrue);
    });

    test('DSP 各项开关读写', () async {
      final prefs = PreferencesService.instance;
      await prefs.setDspEnabled(true);
      await prefs.setDspCrossfeed(true);
      await prefs.setDspWidener(true);
      await prefs.setDspLimiter(true);
      await prefs.setDspDither(true);
      expect(prefs.dspEnabled, isTrue);
      expect(prefs.dspCrossfeed, isTrue);
      expect(prefs.dspWidener, isTrue);
      expect(prefs.dspLimiter, isTrue);
      expect(prefs.dspDither, isTrue);
    });

    test('ReplayGain / 动态取色 / 封面模糊读写', () async {
      final prefs = PreferencesService.instance;
      await prefs.setReplayGain(false);
      await prefs.setDynamicColor(false);
      await prefs.setCoverBlur(0.3);
      expect(prefs.replayGain, isFalse);
      expect(prefs.dynamicColor, isFalse);
      expect(prefs.coverBlur, 0.3);
    });

    test('收藏集合读写', () async {
      final prefs = PreferencesService.instance;
      expect(prefs.favorites, isEmpty);
      await prefs.setFavorites({'a', 'b'});
      expect(prefs.favorites, {'a', 'b'});
    });

    test('搜索历史：添加去重并限制长度', () async {
      final prefs = PreferencesService.instance;
      await prefs.addSearchHistory('hello');
      await prefs.addSearchHistory('world');
      await prefs.addSearchHistory('hello'); // 重复应置顶去重
      final history = prefs.searchHistory;
      expect(history.length, 2);
      expect(history.first, 'hello');
    });

    test('搜索历史：删除与清空', () async {
      final prefs = PreferencesService.instance;
      await prefs.addSearchHistory('a');
      await prefs.addSearchHistory('b');
      await prefs.removeSearchHistory('a');
      expect(prefs.searchHistory, ['b']);
      await prefs.clearSearchHistory();
      expect(prefs.searchHistory, isEmpty);
    });

    test('播放列表读写', () async {
      final prefs = PreferencesService.instance;
      await prefs.savePlaylist('我的列表', ['s1', 's2']);
      final data = prefs.playlists;
      expect(data['我的列表'], ['s1', 's2']);
    });

    test('搜索历史超过 20 条自动截断', () async {
      final prefs = PreferencesService.instance;
      for (var i = 0; i < 25; i++) {
        await prefs.addSearchHistory('term$i');
      }
      expect(prefs.searchHistory.length, 20);
    });
  });
}
