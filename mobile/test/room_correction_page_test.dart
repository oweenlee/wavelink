import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/data/services/rust_service.dart' as rs;
import 'package:wavelink_mobile/l10n/app_localizations.dart';
import 'package:wavelink_mobile/ui/core/providers/repositories.dart';
import 'package:wavelink_mobile/ui/core/theme/app_theme.dart';
import 'package:wavelink_mobile/ui/features/settings/views/room_correction_page.dart';
import 'helpers/mock_repositories.dart';

/// 房间校正页渲染测试：走「粘贴 REW → 生成并应用 → 报告」全流程，
/// 覆盖图表 CustomPaint 与报告状态的渲染路径（真机点开页面即渲染）。
/// 继承 MockAudioEngineRepository：播放链路（init/deinit/play）同样 mock，
/// 避免测试环境触发 flutter_rust_bridge 未初始化异常。
class _FakeRoomRepo extends MockAudioEngineRepository {
  /// 测试环境无 RustLib.init（rustAvailable=false），而 DspNotifier 的
  /// parseRewText / generateAndApply 有 rustAvailable 守卫——模拟真机状态
  @override
  bool get rustAvailable => true;

  @override
  Future<rs.CorrectionConfig> defaultCorrectionConfig() async =>
      rs.CorrectionConfig(
        target: 'flat',
        taps: 8192,
        maxCutDb: 12,
        nullLimitDb: 3,
        freqMin: 20,
        freqMax: 16000,
        psychoWeighting: true,
        smoothingOctave: 1 / 6,
        headroomDb: 3,
      );

  @override
  Future<List<rs.FreqPoint>> parseRewText(String text) async => const [
    rs.FreqPoint(freq: 20, levelDb: -1.5),
    rs.FreqPoint(freq: 100, levelDb: 2.3),
    rs.FreqPoint(freq: 120, levelDb: 8.0),
    rs.FreqPoint(freq: 1000, levelDb: 0.1),
    rs.FreqPoint(freq: 8000, levelDb: -2.0),
    rs.FreqPoint(freq: 20000, levelDb: 0.5),
  ];

  @override
  Future<rs.RoomCorrectionResult> generateRoomCorrection({
    required String rewTxt,
    required rs.CorrectionConfig config,
    required int sampleRate,
  }) async => rs.RoomCorrectionResult(
    ir: Float32List.fromList(List.filled(config.taps, 0)),
    sampleRate: 44100,
    appliedGainDb: -3,
    points: BigInt.from(6),
    measured: const [
      rs.FreqPoint(freq: 20, levelDb: -1.5),
      rs.FreqPoint(freq: 1000, levelDb: 0.1),
    ],
  );

  @override
  Future<void> saveRoomIrWav(
    List<double> ir,
    int sampleRate,
    String path,
  ) async {}

  @override
  Future<void> loadRoomIr(String path) async {}

  @override
  Future<void> clearRoomIr() async {}
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

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioEngineRepositoryProvider.overrideWith((_) => _FakeRoomRepo()),
          preferencesRepositoryProvider.overrideWith(
            (_) => PreferencesRepository(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const AccentScope(
            accent: AppTheme.accentFallback,
            child: RoomCorrectionPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('页面初始渲染（无数据）：不崩溃', (tester) async {
    await pumpPage(tester);
    expect(find.text('房间校正'), findsOneWidget);
    // 生成按钮在视口下方（ListView 惰性构建），滚动到后再断言为禁用态
    await tester.scrollUntilVisible(
      find.text('生成并应用'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final btn = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    check(btn.onPressed).isNull();
  });

  testWidgets('粘贴 REW → 图表渲染 → 生成并应用 → 报告渲染', (tester) async {
    await pumpPage(tester);

    // 打开粘贴对话框
    await tester.tap(find.text('粘贴 REW 文本'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Freq (Hz), Level (dB)\n20, -1.5\n100, 2.3\n',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 数据徽标出现（点数 + 频段）
    expect(find.textContaining('有效测量点'), findsOneWidget);

    // 滚动到底部点击生成并应用
    await tester.scrollUntilVisible(
      find.text('生成并应用'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    check(btn.onPressed).isNotNull();
    await tester.tap(find.text('生成并应用'));
    await tester.pumpAndSettle();

    // 报告渲染（滤波器长度 + 整体衰减提示），不崩溃
    await tester.scrollUntilVisible(
      find.text('清除校正'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('滤波器长度'), findsOneWidget);
    expect(find.textContaining('整体衰减'), findsOneWidget);
  });
}