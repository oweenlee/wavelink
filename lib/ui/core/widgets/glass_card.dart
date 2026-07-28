import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final double blur;
  final double borderRadius;
  final Color? tint;
  final double opacity;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final double? height;
  final double? width;

  const GlassCard({
    super.key,
    required this.child,
    this.blur = 20,
    this.borderRadius = 16,
    this.tint,
    this.opacity = 0.4,
    this.padding,
    this.margin,
    this.onTap,
    this.height,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          height: height,
          width: width,
          padding: padding ?? const EdgeInsets.all(16),
          margin: margin,
          decoration: BoxDecoration(
            color: (tint ?? AppTheme.surfaceDark).withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border(
              top: BorderSide(color: AppTheme.edgeHighlight, width: 0.5),
            ),
          ),
          child: child,
        ),
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: card);
    }
    return card;
  }
}
