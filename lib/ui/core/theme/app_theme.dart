import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// WaveLink 设计令牌
///
/// 色彩哲学：「灰阶为体，随内容为用」
/// - 结构色（S0–S4 中性灰阶）：你在操作 app —— 背景、卡片、表面、边框
/// - 动态色（accent）：你在听音乐 —— 播放按钮/进度/频谱跟随当前歌曲封面主色
/// - 非播放域使用 textPrimary/textSecondary 代替固定品牌色
class AppTheme {
  // ── 灰阶层级（S0 最暗 → S4 最亮）──
  static const Color s0 = Color(0xFF08090A);  // 最深底
  static const Color s1 = Color(0xFF0E1011);  // 主背景
  static const Color s2 = Color(0xFF16191B);  // 卡片/弹窗
  static const Color s3 = Color(0xFF1F2427);  // 高亮表面
  static const Color s4 = Color(0xFF2A3033);  // 边框/分隔

  // ── 兼容旧引用（渐进式别名）──
  static const Color background = s1;
  static const Color surfaceDark = s2;
  static const Color surfaceHigh = s3;

  // ── 品牌（去琥珀金，改为中性白）
  // 旧代码中 62 处引用 AppTheme.brand 的地方自动变为中性白，
  // 不再闪琥珀金。播放域通过 AccentScope.of(context) 获取动态色。
  static const Color brand = textPrimary;

  // ── 文字（冷白灰）──
  static const Color textPrimary = Color(0xFFF0F1F3);     // 94%
  static const Color textSecondary = Color(0xFF9A9FA6);   // 60%
  static const Color textTertiary = Color(0xFF5C6166);    // 36%
  static const Color textDisabled = Color(0xFF3A3F43);    // 23%

  // ── 强调（由封面动态提取，这里仅作 fallback）──
  static const Color accentFallback = Color(0xFFE8553F);  // 橙红，仅用于无封面时

  // ── 高亮/分割 ──
  static const Color highlight = Color(0x0FFFFFFF);       // 6% 白
  static const Color highlightStrong = Color(0x1FFFFFFF); // 12% 白
  static const Color divider = Color(0x14FFFFFF);         // 8% 白
  static const Color edgeHighlight = highlightStrong;     // 兼容旧引用

  // ── 语义色 ──
  static const Color ok = Color(0xFF4EC9A0);       // 绿色（成功/正常）
  static const Color warn = Color(0xFFE8B33D);     // 黄色（警告）
  static const Color danger = Color(0xFFE85D5D);   // 红色（危险/错误）
  static const Color success = ok;

  // ── 占位色盘已移除 — dominantColor 统一使用 s2 ──

  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: s1,
    colorScheme: const ColorScheme.dark(
      primary: accentFallback,
      secondary: accentFallback,
      surface: surfaceDark,
      error: danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: s1,
      elevation: 0,
      selectedItemColor: textPrimary,
      unselectedItemColor: textTertiary,
      type: BottomNavigationBarType.fixed,
      selectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
      unselectedLabelStyle: TextStyle(fontSize: 10),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: textPrimary,
        height: 1.2,
      ),
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        height: 1.3,
      ),
      headlineSmall: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        height: 1.3,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: textPrimary,
        height: 1.4,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: textSecondary,
        height: 1.3,
      ),
      bodySmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: textTertiary,
        height: 1.2,
      ),
      labelSmall: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        height: 1.0,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: divider,
      thickness: 0.5,
    ),
  );

  static BoxDecoration glassDecoration({
    double blur = 20,
    double borderRadius = 16,
    Color? tint,
    double opacity = 0.4,
  }) {
    return BoxDecoration(
      color: (tint ?? surfaceDark).withValues(alpha: opacity),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border(top: BorderSide(color: edgeHighlight, width: 0.5)),
    );
  }

  static Widget glassContainer({
    required Widget child,
    double blur = 20,
    double borderRadius = 16,
    Color? tint,
    double opacity = 0.4,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          margin: margin,
          padding: padding,
          decoration: glassDecoration(
            blur: blur,
            borderRadius: borderRadius,
            tint: tint,
            opacity: opacity,
          ),
          child: child,
        ),
      ),
    );
  }
}

// ── 排版辅助类 ──

/// 强制字体规则：
/// - display = SpaceGrotesk（标题、大号文字）
/// - body = Inter（正文，通过 ThemeData 全局生效）
/// - mono = JetBrainsMono（采样率/位深/格式/BPM/调性/时间码/计数器 — 必须等宽）
class WlText {
  static const String _display = 'SpaceGrotesk';
  static const String _mono = 'JetBrainsMono';

  /// 技术读数专用样式（必须等宽）
  /// 用于：采样率、位深、格式标签、BPM、调性、时间码、underrun 计数
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

// ── 动态强调色机制 ──

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
/// 播放域（NowPlayingPage / MiniPlayerBar）注入当前歌曲主色，
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
