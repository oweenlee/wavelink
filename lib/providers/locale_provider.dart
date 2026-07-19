import 'package:flutter/material.dart';
import 'package:wavelink_mobile/services/preferences_service.dart';

/// 管理当前界面语言。
/// - 'system'：跟随系统语言（取 [WidgetsBinding] 的设备 locale，命中 zh/en 才用，否则回退英文）
/// - 'zh' / 'en'：手动锁定
class LocaleProvider extends ChangeNotifier {
  /// 'system' | 'zh' | 'en'
  String _mode;

  LocaleProvider() : _mode = PreferencesService.instance.localePref;

  String get mode => _mode;

  /// 当前实际生效的 locale（system 模式下由外部注入设备 locale 计算）
  Locale? _locale;
  Locale? get locale => _locale;

  static const supported = [Locale('zh'), Locale('en')];

  /// 根据设备 locale 与当前模式解析出最终 locale。
  /// [deviceLocale] 来自 [PlatformDispatcher] / [WidgetsBinding]。
  Locale resolve(Locale? deviceLocale) {
    if (_mode == 'system') {
      final lang = deviceLocale?.languageCode;
      _locale = (lang == 'zh') ? const Locale('zh') : const Locale('en');
    } else {
      _locale = Locale(_mode);
    }
    return _locale!;
  }

  void setMode(String mode) {
    if (_mode == mode) return;
    _mode = mode;
    PreferencesService.instance.setLocalePref(mode);
    notifyListeners();
  }
}
