import 'package:flutter/material.dart';

/// WaveLink 设计令牌（与 mobile `ui/core/theme/app_theme.dart` 对齐）
///
/// 色彩哲学：「灰阶为体，随内容为用」
/// - 结构色（S0–S4 中性灰阶）：你在操作 app —— 背景、卡片、表面、边框
/// - 动态色（accent）：你在听音乐 —— 播放按钮/进度跟随当前歌曲封面主色
/// - 非播放域使用 textPrimary/textSecondary 代替固定品牌色
class AppTheme {
  // ── 灰阶层级（S0 最暗 → S4 最亮）──
  static const Color s0 = Color(0xFF08090A); // 最深底
  static const Color s1 = Color(0xFF0E1011); // 主背景
  static const Color s2 = Color(0xFF16191B); // 卡片/弹窗
  static const Color s3 = Color(0xFF1F2427); // 高亮表面
  static const Color s4 = Color(0xFF2A3033); // 边框/分隔

  // ── 文字（冷白灰）──
  static const Color textPrimary = Color(0xFFF0F1F3); // 94%
  static const Color textSecondary = Color(0xFF9A9FA6); // 60%
  static const Color textTertiary = Color(0xFF5C6166); // 36%
  static const Color textDisabled = Color(0xFF3A3F43); // 23%

  // ── 强调（由封面动态提取，这里仅作 fallback）──
  static const Color accentFallback = Color(0xFFE8553F); // 橙红，仅无封面时

  // ── 高亮/分割 ──
  static const Color highlight = Color(0x0FFFFFFF); // 6% 白
  static const Color highlightStrong = Color(0x1FFFFFFF); // 12% 白
  static const Color divider = Color(0x14FFFFFF); // 8% 白

  // ── 语义色 ──
  static const Color ok = Color(0xFF4EC9A0);
  static const Color warn = Color(0xFFE8B33D);
  static const Color danger = Color(0xFFE85D5D);

  // ── 桌面端旧别名（渐进迁移，语义按 mobile 令牌归位）──
  static const Color surface = s2;
  static const Color surfaceHigh = s3;
  static const Color background = s1;
}

// ── 旧引用兼容（home.dart 等处的局部别名指向这些）──
const kSurface = AppTheme.s2;
const kSurface2 = AppTheme.s3;
const kOnSurface = AppTheme.textPrimary;
const kOnSurfaceVariant = AppTheme.textSecondary;
const kBorder = AppTheme.highlightStrong;
const kScaffoldBackground = AppTheme.s1;

/// App 主题（暗色，Inter 为全局正文字体，与 mobile 一致）。
ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: AppTheme.s1,
    colorScheme: ColorScheme.dark(
      brightness: Brightness.dark,
      surface: AppTheme.s2,
      surfaceContainerHighest: AppTheme.s3,
      onSurface: AppTheme.textPrimary,
      onSurfaceVariant: AppTheme.textSecondary,
      outline: AppTheme.s4,
      primary: AppTheme.textPrimary,
      error: AppTheme.danger,
    ),
    dividerColor: AppTheme.divider,
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppTheme.textPrimary,
        height: 1.3,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: AppTheme.textPrimary,
        height: 1.4,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppTheme.textSecondary,
        height: 1.3,
      ),
      bodySmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: AppTheme.textTertiary,
        height: 1.2,
      ),
    ),
    // ── 去「Flutter 系统味」：移除 Material 默认 ripple / 组件 elevation 染色 ──
    // 这些默认值（点击水波纹、表面染色、对话框浮起、弹窗阴影）是 Flutter 味的
    // 主来源；桌面端统一接管为「无墨水 + 边框分层 + 平铺表面」。
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: AppTheme.highlight, // 桌面 hover 反馈保留为极淡白，避免「死板」
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: AppTheme.s1,
      foregroundColor: AppTheme.textPrimary,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      color: AppTheme.s2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.highlightStrong),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: AppTheme.s2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      color: AppTheme.s2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
    ),
    dividerTheme: DividerThemeData(
      color: AppTheme.divider,
      thickness: 1,
      space: 0,
    ),
    listTileTheme: ListTileThemeData(
      tileColor: Colors.transparent,
      iconColor: AppTheme.textSecondary,
      textColor: AppTheme.textPrimary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      // 去掉拖动时的默认交互光环（material 的「按压环」很出戏）
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
      overlayColor: AppTheme.highlight,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.all(AppTheme.textTertiary.withAlpha(120)),
      trackColor: WidgetStateProperty.all(Colors.transparent),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppTheme.textPrimary,
      selectionColor: AppTheme.highlightStrong,
      selectionHandleColor: AppTheme.textPrimary,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppTheme.s3,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
  );
}

// ── 排版辅助类（与 mobile WlText 对齐）──

/// 强制字体规则：
/// - display = SpaceGrotesk（标题、大号文字）
/// - body = Inter（正文，通过 ThemeData 全局生效）
/// - mono = JetBrainsMono（采样率/位深/格式/时间码 — 必须等宽）
class WlText {
  static const String _display = 'SpaceGrotesk';
  static const String _mono = 'JetBrainsMono';

  /// 技术读数专用样式（必须等宽）：时间码、格式标签、比特率
  static TextStyle mono({
    double? fontSize,
    Color? color,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: _mono,
      fontSize: fontSize ?? 11,
      color: color ?? AppTheme.textSecondary,
      fontWeight: fontWeight ?? FontWeight.w500,
      letterSpacing: letterSpacing ?? 0.3,
      height: height,
    );
  }

  /// 标题样式（display face）
  static TextStyle display({
    double? fontSize,
    Color? color,
    FontWeight? fontWeight,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: _display,
      fontSize: fontSize ?? 22,
      color: color ?? AppTheme.textPrimary,
      fontWeight: fontWeight ?? FontWeight.w700,
      letterSpacing: letterSpacing ?? -0.3,
    );
  }
}

// ── 动态强调色机制（与 mobile 对齐）──

/// 把任意封面主色规整为可安全用作控件色的强调色。
/// 钳制饱和度与亮度，避免太暗（按钮看不清）或太艳（刺眼）。
extension AccentNormalize on Color {
  Color toAccent() {
    final hsl = HSLColor.fromColor(this);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.45, 0.85))
        .withLightness(hsl.lightness.clamp(0.55, 0.72))
        .toColor();
  }

  /// 以本色为背景时应使用的文字/图标色（深底白字，浅底深字）。
  Color get onAccent =>
      computeLuminance() > 0.45 ? AppTheme.background : Colors.white;
}

/// 向子树注入「当前强调色」。
///
/// 播放域（正在播放面板/底部控制条）注入当前歌曲主色，
/// 其余位置 [of] 自动回退到 [AppTheme.accentFallback]。
class AccentScope extends InheritedWidget {
  final Color accent;

  const AccentScope({super.key, required this.accent, required super.child});

  static Color of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AccentScope>();
    return scope?.accent ?? AppTheme.accentFallback;
  }

  @override
  bool updateShouldNotify(AccentScope oldWidget) => accent != oldWidget.accent;
}
