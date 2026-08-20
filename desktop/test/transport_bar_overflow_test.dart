import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/l10n/app_localizations.dart';
import 'package:local_music_player/screens/home.dart';
import 'package:local_music_player/services/network_source_config.dart';

Widget _app(Widget child) => ProviderScope(
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

/// 回归测试：传输栏横跨整个窗口宽度（home.dart:291），窄窗口下中心控件最小宽
/// 必须优先于左信息分配，否则 W540 附近会出现 RenderFlex 右溢（见审计 item 22）。
void main() {
  testWidgets('传输栏在窄窗口不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await NetworkSourceConfig.init();
    const widths = [540.0, 560.0, 600.0, 720.0];
    for (final w in widths) {
      await tester.binding.setSurfaceSize(Size(w, 720));
      await tester.pumpWidget(_app(const HomeScreen()));
      await tester.pump();
      final e = tester.takeException();
      final overflowed =
          e != null && e.toString().contains(RegExp(r'overflowed by'));
      expect(overflowed, isFalse,
          reason: '窗口宽 ${w.toInt()}px 时传输栏出现 RenderFlex 溢出: $e');
    }
  });
}
