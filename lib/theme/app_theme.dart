import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class AppTheme {
  static const Color background = Color(0xFF0D0D1A);
  static const Color surfaceDark = Color(0xFF1A1A2E);
  static const Color accentBlue = Color(0xFF0A84FF);
  static const Color accentPurple = Color(0xFFB388FF);
  static const Color textPrimary = Color(0xDDFFFFFF);
  static const Color textSecondary = Color(0x8CFFFFFF);
  static const Color textTertiary = Color(0x4DFFFFFF);
  static const Color danger = Color(0xFFFF453A);
  static const Color success = Color(0xFF30D158);
  static const Color edgeHighlight = Color(0x1AFFFFFF);

  /// 专辑/歌手占位色盘（确定性，按 path hash 取模）
  static const List<Color> palette = [
    Color(0xFF6C5CE7), Color(0xFF00B894), Color(0xFFFD79A8),
    Color(0xFF0984E3), Color(0xFFE17055), Color(0xFF00CEC9),
    Color(0xFFFDCB6E), Color(0xFFA29BFE), Color(0xFF55EFC4),
    Color(0xFFFAB1A0), Color(0xFF74B9FF), Color(0xFFDFE6E9),
    Color(0xFFE84393), Color(0xFF6C5CE7), Color(0xFFFDCB6E),
    Color(0xFFE17055), Color(0xFF00CEC9), Color(0xFFFD79A8),
    Color(0xFF0984E3), Color(0xFF00B894),
  ];

  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: accentBlue,
      secondary: accentPurple,
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
      selectedItemColor: accentBlue,
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
