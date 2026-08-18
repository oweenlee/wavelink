import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_source_config.dart';

/// 管理当前界面语言（与 mobile 的 LocaleNotifier 对齐）。
/// - 'system'：跟随系统语言（取设备 locale，命中 zh/ja/de/en 才用，否则回退英文）
/// - 'zh' / 'ja' / 'de' / 'en'：手动锁定
class LocaleNotifier extends Notifier<String> {
  static const supported = [
    Locale('zh'),
    Locale('ja'),
    Locale('de'),
    Locale('en'),
  ];

  @override
  String build() => NetworkSourceConfig.instance.localePref;

  /// 根据设备 locale 与当前模式解析出最终 locale（纯函数，不改状态）。
  /// [deviceLocale] 来自 [PlatformDispatcher] / [WidgetsBinding]。
  static Locale resolve(String mode, Locale? deviceLocale) {
    if (mode == 'system') {
      final lang = deviceLocale?.languageCode;
      return switch (lang) {
        'zh' => const Locale('zh'),
        'ja' => const Locale('ja'),
        'de' => const Locale('de'),
        'en' => const Locale('en'),
        _ => const Locale('en'),
      };
    }
    return Locale(mode);
  }

  void setMode(String mode) {
    if (state == mode) return;
    state = mode;
    // 持久化后台写入（locale 偏好非关键，丢一次也仅回退 system）
    NetworkSourceConfig.instance.setLocalePref(mode);
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, String>(
  LocaleNotifier.new,
);
