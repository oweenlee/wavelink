import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/l10n/app_localizations.dart';
import 'package:local_music_player/screens/settings.dart';
import 'package:local_music_player/services/engine.dart';
import 'package:local_music_player/services/network_source_config.dart';
import 'package:local_music_player/services/player_controller.dart';

/// 测试用 MaterialApp 外壳：同 widget_test.dart，必须注册本地化 delegate。
Widget _testApp(Widget child) => ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

/// 把设置页泵入测试视口。主从布局下每个 section 单独挂载，视口高度给足
/// 避免内容区滚动导致 tap 命中不到（DSP 区较高，1100px 可整屏容纳）。
Future<void> _pumpSettings(WidgetTester tester, PlayerController player) async {
  await tester.binding.setSurfaceSize(const Size(980, 1100));
  await tester.pumpWidget(_testApp(SettingsScreen(player: player)));
  await tester.pumpAndSettle();
}

/// 点左侧导航切到指定分类（key: general/audio/dsp/diag）。
Future<void> _selectSection(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key('nav_$key')));
  await tester.pumpAndSettle();
}

/// 记录所有调用的假引擎（不依赖 Rust 动态库）。
class FakeEngine extends Engine {
  final Map<String, dynamic> calls = {};
  bool reinitializedExclusive = false;

  @override
  Future<List<String>> enumerateDevices() async =>
      const ['内置扬声器', 'HDMI'];

  @override
  Future<void> setOutputDevice(String? name) async =>
      calls['setOutputDevice'] = name;

  @override
  Future<int> outputSampleRate() async => 48000;

  @override
  Future<String?> reinitialize({
    bool exclusiveMode = false,
    bool? bitPerfect,
    bool? autoSampleRate,
  }) async {
    reinitializedExclusive = exclusiveMode;
    if (bitPerfect != null) calls['bitPerfect'] = bitPerfect;
    if (autoSampleRate != null) calls['autoSampleRate'] = autoSampleRate;
    return null;
  }

  @override
  Future<void> setOutputSampleRate(int rate) async =>
      calls['setOutputSampleRate'] = rate;

  @override
  Future<void> setStereoWidener(bool enabled, double width) async =>
      calls['setStereoWidener'] = [enabled, width];

  @override
  Future<void> setCrossfeed(bool enabled) async =>
      calls['setCrossfeed'] = enabled;

  @override
  Future<void> setLimiter(bool enabled) async => calls['setLimiter'] = enabled;

  @override
  Future<void> setDither(bool enabled) async => calls['setDither'] = enabled;

  @override
  Future<void> setNoiseShaping(bool enabled) async =>
      calls['setNoiseShaping'] = enabled;

  @override
  Future<void> setReplaygainGain(double gainDb) async =>
      calls['setReplaygainGain'] = gainDb;

  @override
  Future<void> setSpeed(double speed) async => calls['setSpeed'] = speed;

  @override
  Future<void> applyPreset(String presetName) async =>
      calls['applyPreset'] = presetName;

  @override
  Future<void> setAutoEq(String? model) async => calls['setAutoEq'] = model;

  @override
  Future<List<String>> autoEqCatalog() async => ['HD650', 'HD800S'];

  @override
  Future<void> loadIr(String path) async => calls['loadIr'] = path;

  @override
  Future<void> clearIr() async => calls['clearIr'] = true;

  @override
  Future<int> underrunCount() async => 0;

  @override
  Future<String> lastError() async => '';

  @override
  Future<String> currentPath() async => '';
}

/// 注入假引擎、记录 clearAllData 的假 PlayerController。
class FakePlayerController extends PlayerController {
  final Engine _testEngine;
  bool clearAllCalled = false;

  FakePlayerController(this._testEngine);

  @override
  Engine? get engine => _testEngine;

  @override
  Future<void> clearAllData() async => clearAllCalled = true;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // localeProvider 依赖 NetworkSourceConfig，未 init 会抛 ProviderException
    await NetworkSourceConfig.init();
  });

  group('SettingsScreen', () {
    testWidgets('renders nav + all sections and engine-null hint',
        (tester) async {
      final player = PlayerController(); // engine 未加载
      await _pumpSettings(tester, player);

      // 导航栏 4 项齐全
      expect(find.byKey(const Key('nav_general')), findsOneWidget);
      expect(find.byKey(const Key('nav_audio')), findsOneWidget);
      expect(find.byKey(const Key('nav_dsp')), findsOneWidget);
      expect(find.byKey(const Key('nav_diag')), findsOneWidget);

      // 默认选中「通用」，引擎未加载横幅存在
      expect(find.byKey(const Key('sec_general')), findsOneWidget);
      expect(find.textContaining('音频引擎未加载'), findsOneWidget);

      // 逐一切换分类，校验对应内容标题出现
      await _selectSection(tester, 'audio');
      expect(find.byKey(const Key('sec_audio')), findsOneWidget);
      await _selectSection(tester, 'dsp');
      expect(find.byKey(const Key('sec_dsp')), findsOneWidget);
      await _selectSection(tester, 'diag');
      expect(find.byKey(const Key('sec_diag')), findsOneWidget);
    });

    testWidgets('DSP toggles call engine methods', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'dsp');

      // 立体声展宽开关 → setStereoWidener(true, 0.5)
      final widenerSwitch = find.descendant(
        of: find.byKey(const Key('sw_立体声展宽')),
        matching: find.byType(Switch),
      );
      await tester.tap(widenerSwitch);
      await tester.pump();
      expect(fake.calls['setStereoWidener'], [true, 0.5]);

      // 跨馈开关 → setCrossfeed(true)
      final crossSwitch = find.descendant(
        of: find.byKey(const Key('sw_跨馈 (Crossfeed)')),
        matching: find.byType(Switch),
      );
      await tester.tap(crossSwitch);
      await tester.pump();
      expect(fake.calls['setCrossfeed'], isTrue);
    });

    testWidgets('sample-rate apply calls setOutputSampleRate', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'audio');

      await tester.enterText(find.byKey(const Key('sr_field')), '48000');
      await tester.tap(find.byKey(const Key('sr_apply')));
      await tester.pump();
      expect(fake.calls['setOutputSampleRate'], 48000);
    });

    testWidgets('EQ preset dropdown applies preset', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'dsp');

      await tester.tap(find.byKey(const Key('preset_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('rock').last);
      await tester.pumpAndSettle();
      expect(fake.calls['applyPreset'], 'rock');
    });

    testWidgets('FIR clear calls clearIr', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'dsp');

      await tester.ensureVisible(find.byKey(const Key('fir_clear')));
      await tester.tap(find.byKey(const Key('fir_clear')));
      await tester.pump();
      expect(fake.calls['clearIr'], isTrue);
    });

    testWidgets('DSP toggle persists to prefs and rehydrates',
        (tester) async {
      SharedPreferences.setMockInitialValues({'dsp.crossfeed': true});
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'dsp');

      // 回显：prefs 中已开启的跨馈在 UI 上应为开
      final crossSwitch = tester.widget<Switch>(find.descendant(
        of: find.byKey(const Key('sw_跨馈 (Crossfeed)')),
        matching: find.byType(Switch),
      ));
      expect(crossSwitch.value, isTrue);

      // 新切换的限幅开关即时落盘
      final limiterSwitch = find.descendant(
        of: find.byKey(const Key('sw_真峰值限幅 (Limiter)')),
        matching: find.byType(Switch),
      );
      await tester.tap(limiterSwitch);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('dsp.limiter'), isTrue);
    });

    testWidgets('engine toggles persist to prefs and rehydrate',
        (tester) async {
      SharedPreferences.setMockInitialValues({'engine.bitPerfect': true});
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'audio');

      // 回显：prefs 中已开启的 BitPerfect 在 UI 上应为开
      final bpSwitch = tester.widget<Switch>(find.descendant(
        of: find.byKey(const Key('sw_bitperfect')),
        matching: find.byType(Switch),
      ));
      expect(bpSwitch.value, isTrue);

      // 新切换的 AutoSampleRate 即时落盘
      final asrSwitch = find.descendant(
        of: find.byKey(const Key('sw_autosr')),
        matching: find.byType(Switch),
      );
      await tester.tap(asrSwitch);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('engine.autoSampleRate'), isTrue);
    });

    testWidgets('AutoEQ picker selects catalog model', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'dsp');

      // 打开选择器 → 弹 catalog（含关闭项 + 型号）
      await tester.tap(find.byKey(const Key('autoeq_picker')));
      await tester.pumpAndSettle();
      expect(find.text('关闭 AutoEQ'), findsWidgets);
      await tester.tap(find.text('HD650'));
      await tester.pumpAndSettle();

      // 选中即应用：engine.setAutoEq + prefs 落盘
      expect(fake.calls['setAutoEq'], 'HD650');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dsp.autoEq'), 'HD650');
    });

    testWidgets('clear-all flow calls player.clearAllData', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'general');

      await tester.tap(find.widgetWithText(OutlinedButton, '清空所有数据'));
      await tester.pumpAndSettle();
      expect(
        find.text('将删除全部曲库、收藏与播放列表，且不可恢复。'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, '清空'));
      await tester.pumpAndSettle();
      expect(player.clearAllCalled, isTrue);
    });

    testWidgets('exclusive switch shown on Windows and macOS', (tester) async {
      final fake = FakeEngine();
      final player = FakePlayerController(fake);
      await _pumpSettings(tester, player);
      await _selectSection(tester, 'audio');

      final shown = Platform.isWindows || Platform.isMacOS;
      if (shown) {
        expect(find.byKey(const Key('sw_exclusive')), findsOneWidget);
        await tester.tap(find.descendant(
          of: find.byKey(const Key('sw_exclusive')),
          matching: find.byType(Switch),
        ));
        await tester.pumpAndSettle();
        expect(fake.reinitializedExclusive, isTrue);
      } else {
        expect(find.byKey(const Key('sw_exclusive')), findsNothing);
      }
    });
  });
}
