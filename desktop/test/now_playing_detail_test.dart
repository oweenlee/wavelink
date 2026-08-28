import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/core/format.dart';
import 'package:local_music_player/l10n/app_localizations.dart';
import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/screens/now_playing.dart';
import 'package:local_music_player/screens/now_playing_detail.dart';
import 'package:local_music_player/services/player_notifier.dart';
import 'package:local_music_player/services/player_providers.dart';

/// 注入固定曲目与进度的 PlayerNotifier：覆写 build 直接给状态，
/// 不触发引擎加载 / 续播恢复（flutter test 宿主无 dylib）。
class _FakePlayerNotifier extends PlayerNotifier {
  _FakePlayerNotifier(this._tracks);

  final List<Track> _tracks;

  @override
  PlayerState build() => PlayerState(
    queue: _tracks,
    queueIndex: _tracks.isEmpty ? null : 0,
    duration: const Duration(seconds: 245),
    position: const Duration(seconds: 61),
  );
}

Track _localTrack() => const Track(
  id: 'local-1',
  title: 'Kind of Blue',
  artist: 'Miles Davis',
  album: 'Kind of Blue',
  filePath: '/Users/qin/Music/Miles Davis/01 - So What.flac',
  trackNumber: 1,
);

Track _subsonicTrack() => const Track(
  id: 'sub-1',
  title: 'Streaming Track',
  artist: 'Remote Artist',
  source: TrackSource.subsonic,
  streamUrl: 'https://nas.example.com/rest/stream?id=42&u=qin&p=secret',
  fileSize: 48234496,
  durationHint: Duration(seconds: 245),
  durationEstimated: true,
);

/// 测试外壳：注册本地化 delegate 并固定 zh（与 widget_test.dart 同机制），
/// 面板按桌面实际宽度（340）渲染。
Widget _shell(PlayerNotifier player, Widget child) => ProviderScope(
  overrides: [playerProvider.overrideWith(() => player)],
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SizedBox(width: 340, height: 800, child: child)),
  ),
);

void main() {
  setUp(() async {
    // shared_preferences 原生 channel 在测试宿主无响应，需先给 mock 初始值。
    SharedPreferences.setMockInitialValues({});
  });

  group('详情读数纯函数', () {
    test('本地文件取扩展名，CUE 分轨标注 CUE', () {
      expect(trackFormatLabel(_localTrack()), 'FLAC');
      expect(
        trackFormatLabel(
          _localTrack().copyWith(
            filePath: '/Music/album.cue',
            cuePath: '/Music/album.cue',
            cueTrackIndex: 3,
          ),
        ),
        'CUE',
      );
    });

    test('网络曲目无扩展名时回落音源短名', () {
      expect(trackFormatLabel(_subsonicTrack()), 'SUB');
    });

    test('流地址脱敏：去掉带凭据的 query', () {
      expect(
        trackLocationLabel(_subsonicTrack()),
        'https://nas.example.com/rest/stream',
      );
    });

    test('文件体积按 1024 进制格式化', () {
      expect(fmtBytes(null), '—');
      expect(fmtBytes(512), '512 B');
      expect(fmtBytes(48234496), '46.0 MB');
    });
  });

  testWidgets('无曲目时详情页显示空态引导', (tester) async {
    final player = _FakePlayerNotifier(const []);
    await tester.pumpWidget(_shell(player, TrackDetailView(player: player)));

    expect(find.text('未在播放'), findsOneWidget);
    expect(find.text('来源与文件'), findsNothing);
  });

  testWidgets('详情页展示来源文件 / 播放 / 音频输出 / 分析四组读数', (tester) async {
    final player = _FakePlayerNotifier([_localTrack()]);
    await tester.pumpWidget(_shell(player, TrackDetailView(player: player)));
    await tester.pumpAndSettle();

    // 分组标题
    expect(find.text('来源与文件'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('音频输出'), findsOneWidget);
    expect(find.text('分析'), findsOneWidget);

    // 读数：格式/时长/进度/输出采样率标签均出现
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('4:05'), findsOneWidget); // 245s
    expect(find.text('1:01 · 25%'), findsOneWidget); // 61s / 245s
    expect(find.text('输出采样率'), findsOneWidget);
    // 未分析时给出明确说明，而不是 0 值
    expect(find.text('尚未分析'), findsOneWidget);
  });

  testWidgets('网络曲目展示远端大小与估算时长标记', (tester) async {
    final player = _FakePlayerNotifier([_subsonicTrack()]);
    await tester.pumpWidget(_shell(player, TrackDetailView(player: player)));
    await tester.pumpAndSettle();

    expect(find.text('46.0 MB'), findsOneWidget);
    expect(find.text('4:05 · 估算'), findsOneWidget);
  });

  testWidgets('播放面板可切到详情页', (tester) async {
    final player = _FakePlayerNotifier([_localTrack()]);
    await tester.pumpWidget(
      _shell(player, NowPlaying(player: player, width: 340)),
    );
    // 不用 pumpAndSettle：正在播放页的频谱是常驻动画，永远 settle 不下来
    await tester.pump();

    // 三个页签齐备，默认停在「正在播放」
    expect(find.text('正在播放'), findsWidgets);
    expect(find.text('详情'), findsOneWidget);
    expect(find.text('来源与文件'), findsNothing);

    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();

    expect(find.text('来源与文件'), findsOneWidget);
    expect(find.text('输出采样率'), findsOneWidget);
  });
}
