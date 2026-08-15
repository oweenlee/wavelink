import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/ui/core/app.dart';
import 'package:wavelink_mobile/domain/models/song.dart';
import 'package:wavelink_mobile/domain/models/lyric_line.dart';
import 'package:wavelink_mobile/ui/features/playback/view_models/playback_controller.dart';
import 'package:wavelink_mobile/ui/core/providers/repositories.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:wavelink_mobile/ui/features/settings/view_models/locale_provider.dart';
import 'package:wavelink_mobile/ui/features/settings/view_models/package_info_provider.dart';
import 'helpers/mock_repositories.dart';

/// 测试用：强制中文（测试设备语言为 en，断言文案为中文）
class _TestLocaleNotifier extends LocaleNotifier {
  @override
  String build() => 'zh';
}

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
    // 镜像 main.dart：mock repos + 强制中文（测试设备语言为 en，断言文案为中文）
    final container = ProviderContainer(
      overrides: [
        audioEngineRepositoryProvider.overrideWith(
          (_) => MockAudioEngineRepository(),
        ),
        songRepositoryProvider.overrideWith((_) => MockSongRepository()),
        preferencesRepositoryProvider.overrideWith(
          (_) => PreferencesRepository(),
        ),
        localeProvider.overrideWith(_TestLocaleNotifier.new),
        // 测试环境无原生插件：固定版本号，避免 PackageInfo 通道异常
        packageInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'wavelink',
            packageName: 'com.wavelink.mobile',
            version: '1.0.0',
            buildNumber: '1',
            buildSignature: '',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // 触发编排层接线并启动副作用（与 main.dart 一致）
    container.read(playbackControllerProvider).bootstrap();
    return UncontrolledProviderScope(
      container: container,
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
