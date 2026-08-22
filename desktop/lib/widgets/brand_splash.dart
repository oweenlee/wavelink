import 'dart:math' show cos, pi;

import 'package:flutter/material.dart';

/// 品牌启动图（移植 mobile `brand_splash.dart`，对齐视觉规格）：
/// 黑底 + App logo + WaveLink 字标 + 脉冲波形。
/// 桌面差异：字体族为 SpaceGrotesk（无空格）、logo/字标略缩以匹配窗口比例。
class BrandSplash extends StatefulWidget {
  const BrandSplash({super.key});

  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  static const List<double> _phases = [0.0, 0.15, 0.30, 0.45, 0.60];
  static const double _minH = 7.0;
  static const double _maxH = 28.0;

  Widget _bar(double v, double d) {
    final t = (v + d) % 1.0;
    final h = _minH + (_maxH - _minH) * (0.5 - 0.5 * cos(2 * pi * t));
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      width: 3,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.splashBg,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // App logo（圆角方块，与 App 图标一致）
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/splash/logo.png',
              width: 72,
              height: 72,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 18),
          // inherit:false：Splash 不在 Material 子树内，默认会合并根
          // DefaultTextStyle 的 debug 黄色双下划线装饰
          const Text(
            'WaveLink',
            style: TextStyle(
              inherit: false,
              fontFamily: 'SpaceGrotesk',
              fontSize: 40,
              fontWeight: FontWeight.w500,
              letterSpacing: 3,
              color: Color(0xFFF5F5F5),
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            height: 30,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [for (final d in _phases) _bar(_ctrl.value, d)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 启动图门：覆盖在首页之上显示 [BrandSplash]，[hold] 后淡出露出内容。
/// 遮蔽 runApp 后 player.init 的异步初始化窗口（大曲库重扫数秒），
/// 避免首帧出现半成品 UI。
class SplashGate extends StatefulWidget {
  final Widget child;
  final Duration hold;

  const SplashGate({
    super.key,
    required this.child,
    // 与 mobile 同规格：500ms 品牌瞬间 + 350ms 淡出
    this.hold = const Duration(milliseconds: 500),
  });

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate>
    with SingleTickerProviderStateMixin {
  bool _showSplash = true;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.hold, () {
      if (!mounted) return;
      _fade.forward().then((_) {
        if (mounted) setState(() => _showSplash = false);
      });
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_showSplash)
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0).animate(_fade),
            child: const BrandSplash(),
          ),
      ],
    );
  }
}

/// 启动图配色（黑底与 mobile 一致，独立常量避免引入 theme 依赖环）。
abstract final class AppColors {
  static const splashBg = Color(0xFF0A0A0A);
}
