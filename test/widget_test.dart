import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/ui/core/app.dart';
import 'package:wavelink_mobile/domain/models/song.dart';
import 'package:wavelink_mobile/domain/models/lyric_line.dart';
import 'package:wavelink_mobile/ui/features/playback/view_models/playback_provider.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:wavelink_mobile/ui/features/settings/view_models/locale_provider.dart';
import 'package:wavelink_mobile/ui/features/library/view_models/library_header_notifier.dart';
import 'helpers/mock_repositories.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
  });

  Widget buildApp() {
    final playback = PlaybackProvider(
      engineRepo: MockAudioEngineRepository(),
      songRepo: MockSongRepository(),
      prefsRepo: PreferencesRepository(),
    );
    // 测试环境设备语言为 en，强制中文以匹配断言文案
    final localeProvider = LocaleProvider()..setMode('zh');
    // 镜像 main.dart 的 Provider 树（WaveLinkApp 需要 playback 及其子 provider + LocaleProvider）
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: playback.queueProvider),
        ChangeNotifierProvider.value(value: playback.audioPlayer),
        ChangeNotifierProvider.value(value: playback.library),
        ChangeNotifierProvider.value(value: playback.dsp),
        ChangeNotifierProvider.value(value: localeProvider),
        ChangeNotifierProvider(create: (_) => LibraryHeaderNotifier()),
      ],
      child: const WaveLinkApp(),
    );
  }

  group('模型', () {
    test('Song.formattedDuration 格式化', () {
      final s = Song(
        id: '1',
        title: 't',
        artist: 'a',
        album: 'al',
        duration: const Duration(minutes: 3, seconds: 5),
        dominantColor: const Color(0xFF000000),
      );
      check(s.formattedDuration).equals('03:05');
    });

    test('Album.totalDuration 累加', () {
      final songs = [
        Song(
          id: '1',
          title: 't1',
          artist: 'a',
          album: 'al',
          duration: const Duration(seconds: 30),
          dominantColor: const Color(0xFF000000),
        ),
        Song(
          id: '2',
          title: 't2',
          artist: 'a',
          album: 'al',
          duration: const Duration(seconds: 45),
          dominantColor: const Color(0xFF000000),
        ),
      ];
      final album = Album(
        id: 'al',
        title: 'al',
        artist: 'a',
        year: 2024,
        songs: songs,
        dominantColor: const Color(0xFF000000),
      );
      check(album.totalDuration).equals(const Duration(seconds: 75));
    });

    test('LyricLine.totalMs 取整', () {
      check(LyricLine(1234.6, 'x').totalMs).equals(1235);
    });
  });

  group('App 渲染', () {
    testWidgets('基础渲染包含三个导航项', (tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.text('曲库'), findsWidgets);
      expect(find.text('播放'), findsWidgets);
      expect(find.text('设置'), findsWidgets);
    });

    testWidgets('默认在曲库页，空状态提示导入', (tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(find.textContaining('导入音乐'), findsWidgets);
    });

    testWidgets('切换到设置页显示音频分区', (tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      // 点击设置导航
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.text('音频'), findsWidgets);
      // “外观”分区在较长的“音频”分区下方，需滚动到可见再断言
      await tester.dragUntilVisible(
        find.text('外观'),
        find.byType(Scrollable).last,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(find.text('外观'), findsWidgets);
    });
  });
}
