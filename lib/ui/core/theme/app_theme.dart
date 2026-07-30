import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// WaveLink 设计令牌
///
/// 色彩哲学：「琥珀为体，随内容为用」
/// - 结构色（brand 琥珀金）：你在操作 app —— Tab、导航、开关、按钮骨架
/// - 动态色（accent）：你在听音乐 —— 播放按钮/进度/频谱跟随当前歌曲封面主色
/// - 语义色（danger/success）：状态反馈
class AppTheme {
  // ── 基底（中性偏暖炭灰，替代原冷靛蓝）──
  static const Color background = Color(0xFF121110);
  static const Color surfaceDark = Color(0xFF1C1A18);
  static const Color surfaceHigh = Color(0xFF262320);

  // ── 品牌（琥珀金，胆机暖光 / VU 表头）──
  static const Color brand = Color(0xFFF0B450);

  // ── 文字 ──
  static const Color textPrimary = Color(0xDDFFFFFF);
  static const Color textSecondary = Color(0x8CFFFFFF);
  static const Color textTertiary = Color(0x4DFFFFFF);

  // ── 语义 ──
  static const Color danger = Color(0xFFF2554A);
  static const Color success = Color(0xFF4CC38A);
  static const Color edgeHighlight = Color(0x1AFFFFFF);

  /// 专辑/歌手占位色盘：13 色，等色相环分布 + 统一 S/L 区间，保证彼此协调。
  /// 用 HSL 生成而非手调，避免高饱和糖果色与暖底色冲突。
  static final List<Color> palette = List.generate(13, (i) {
    final hue = (i * 360.0 / 13 + 18) % 360;
    return HSLColor.fromAHSL(1, hue, 0.56, 0.60).toColor();
  });

  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: brand,
      secondary: brand,
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
      backgroundColor: Colors.transparent,
      elevation: 0,
      selectedItemColor: brand,
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
      color: Color(0x1AFFFFFF),
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
/// 其余位置 [of] 自动回退到品牌金 [AppTheme.brand]。
class AccentScope extends InheritedWidget {
  final Color accent;

  const AccentScope({super.key, required this.accent, required super.child});

  static Color of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AccentScope>();
    return scope?.accent ?? AppTheme.brand;
  }

  @override
  bool updateShouldNotify(AccentScope oldWidget) => accent != oldWidget.accent;
}
