import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:checks/checks.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
  });

  group('PreferencesService 持久化', () {
    test('音量读写', () async {
      final prefs = PreferencesService.instance;
      check(prefs.volume).equals(0.8);
      await prefs.setVolume(0.5);
      check(prefs.volume).equals(0.5);
    });

    test('循环模式读写', () async {
      final prefs = PreferencesService.instance;
      check(prefs.loopMode).equals('list');
      await prefs.setLoopMode('single');
      check(prefs.loopMode).equals('single');
    });

    test('随机开关读写', () async {
      final prefs = PreferencesService.instance;
      check(prefs.shuffle).isFalse();
      await prefs.setShuffle(true);
      check(prefs.shuffle).isTrue();
    });

    test('DSP 各项开关读写', () async {
      final prefs = PreferencesService.instance;
      await prefs.setDspEnabled(true);
      await prefs.setDspCrossfeed(true);
      await prefs.setDspWidener(true);
      await prefs.setDspLimiter(true);
      check(prefs.dspEnabled).isTrue();
      check(prefs.dspCrossfeed).isTrue();
      check(prefs.dspWidener).isTrue();
      check(prefs.dspLimiter).isTrue();
    });

    test('ReplayGain / 封面模糊读写', () async {
      final prefs = PreferencesService.instance;
      await prefs.setReplayGain(false);
      await prefs.setCoverBlur(0.3);
      check(prefs.replayGain).isFalse();
      check(prefs.coverBlur).equals(0.3);
    });

    test('收藏集合读写', () async {
      final prefs = PreferencesService.instance;
      check(prefs.favorites).isEmpty();
      await prefs.setFavorites({'a', 'b'});
      check(prefs.favorites).deepEquals({'a', 'b'});
    });

    test('播放列表读写', () async {
      final prefs = PreferencesService.instance;
      await prefs.savePlaylist('我的列表', ['s1', 's2']);
      final data = prefs.playlists;
      check(data['我的列表']!).deepEquals(['s1', 's2']);
    });
  });
}
