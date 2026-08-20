import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 正在播放指示器：三根仿随机跳动的均衡器竖条（移植自 mobile
/// `ui/core/widgets/now_playing_indicator.dart`，两端行为一致）。
///
/// 用多个错相位 sin 叠加模拟真实音乐节奏（非规律同步），
/// 供歌曲行封面遮罩 / 播放面板共用，避免重复 AnimationController。
class NowPlayingIndicator extends StatefulWidget {
  final double baseHeight;
  final double barScale;
  final double minHeight;
  final double maxHeight;

  const NowPlayingIndicator({
    super.key,
    this.baseHeight = 6,
    this.barScale = 10,
    this.minHeight = 4,
    this.maxHeight = 16,
  });

  @override
  State<NowPlayingIndicator> createState() => _NowPlayingIndicatorState();
}

class _NowPlayingIndicatorState extends State<NowPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac;
  // 每根条独立的随机相位/频率/偏移，产生"此起彼伏"的跳动感
  late final List<double> _phase;
  late final List<double> _freq;
  late final List<double> _offset;

  @override
  void initState() {
    super.initState();
    final rng = math.Random(42);
    _phase = List.generate(3, (_) => rng.nextDouble() * math.pi * 2);
    _freq = List.generate(3, (_) => 0.8 + rng.nextDouble() * 0.8);
    _offset = List.generate(3, (_) => 0.4 + rng.nextDouble() * 0.8);
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  double _barHeight(int i) {
    final t = _ac.value * math.pi * 2;
    final v = _offset[i] +
        math.sin(t * _freq[i] + _phase[i]) * 0.5 +
        math.sin(t * _freq[i] * 2.1 + _phase[i] * 1.7) * 0.3;
    return widget.baseHeight + v.clamp(0.0, 1.0) * widget.barScale;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(3, (i) {
          final h = _barHeight(i).clamp(widget.minHeight, widget.maxHeight);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 2,
              height: h,
              decoration: BoxDecoration(
                color: AccentScope.of(context),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}
