import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../data/services/preferences_service.dart';

/// 管理当前界面语言。
/// - 'system'：跟随系统语言（取 [WidgetsBinding] 的设备 locale，命中 zh/ja/en 才用，否则回退英文）
/// - 'zh' / 'ja' / 'en'：手动锁定
class LocaleNotifier extends Notifier<String> {
  static const supported = [Locale('zh'), Locale('ja'), Locale('en')];

  @override
  String build() => PreferencesService.instance.localePref;

  /// 根据设备 locale 与当前模式解析出最终 locale（纯函数，不改状态）。
  /// [deviceLocale] 来自 [PlatformDispatcher] / [WidgetsBinding]。
  static Locale resolve(String mode, Locale? deviceLocale) {
    if (mode == 'system') {
      final lang = deviceLocale?.languageCode;
      return switch (lang) {
        'zh' => const Locale('zh'),
        'ja' => const Locale('ja'),
        _ => const Locale('en'),
      };
    }
    return Locale(mode);
  }

  void setMode(String mode) {
    if (state == mode) return;
    state = mode;
    PreferencesService.instance.setLocalePref(mode);
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, String>(
  LocaleNotifier.new,
);
