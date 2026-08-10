import 'package:flutter/material.dart';
import 'dart:math' show cos, pi;

/// 品牌进入动画：黑底 + WaveLink 字标 + 脉冲波形。
/// 呼应启动页 A 方案 Pulse，原生静态启动页消失后由本组件接管动效。
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
  static const double _minH = 8.0;
  static const double _maxH = 32.0;

  Widget _bar(double v, double d) {
    final t = (v + d) % 1.0;
    final h = _minH + (_maxH - _minH) * (0.5 - 0.5 * cos(2 * pi * t));
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3.5),
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
      color: const Color(0xFF0A0A0A),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'WaveLink',
            style: TextStyle(
              fontFamily: 'Space Grotesk',
              fontSize: 52,
              fontWeight: FontWeight.w500,
              letterSpacing: 3,
              color: Color(0xFFF5F5F5),
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            height: 34,
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

/// 启动动画门：覆盖在 app 之上显示 [BrandSplash]，[hold] 时长后淡出露出 child。
class SplashGate extends StatefulWidget {
  final Widget child;
  final Duration hold;

  const SplashGate({
    super.key,
    required this.child,
    this.hold = const Duration(milliseconds: 1150),
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
    return ColoredBox(
      color: const Color(0xFF0A0A0A),
      child: Stack(
        children: [
          widget.child,
          if (_showSplash)
            FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(_fade),
              child: const BrandSplash(),
            ),
        ],
      ),
    );
  }
}
