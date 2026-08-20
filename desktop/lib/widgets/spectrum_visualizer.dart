import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/player_controller.dart';

/// 实时频谱可视化（16 频段柱状图）。
///
/// 数据来自引擎 `spectrum` 事件（core 消费线程按音频缓冲推送，
/// ~25-50Hz），经 [PlayerController.spectrumStream] 广播。
///
/// 渲染策略：内部 Ticker 以帧率驱动 CustomPainter，对目标幅值做
/// 「快攻慢放」平滑（attack 快、release 缓），暂停/停止后引擎不再
/// 推送，柱体自然衰减到零而不是瞬间消失。整组件包 RepaintBoundary，
/// 高频重绘不波及「正在播放」面板其余部分（DESIGN_GUIDE P1 项）。
class SpectrumVisualizer extends StatefulWidget {
  final PlayerController player;
  final double height;

  const SpectrumVisualizer({
    super.key,
    required this.player,
    this.height = 40,
  });

  @override
  State<SpectrumVisualizer> createState() => _SpectrumVisualizerState();
}

class _SpectrumVisualizerState extends State<SpectrumVisualizer>
    with SingleTickerProviderStateMixin {
  static const int _bands = 16;

  /// 引擎最新推送的目标幅值（0~1）。
  final List<double> _target = List.filled(_bands, 0);

  /// 实际绘制幅值（每帧向目标逼近，实现平滑）。
  final List<double> _display = List.filled(_bands, 0);

  late final AnimationController _ticker;
  StreamSubscription<List<double>>? _specSub;
  StreamSubscription<bool>? _playingSub;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this)
      ..repeat(min: 0, max: 1, period: const Duration(milliseconds: 500));
    _specSub = widget.player.spectrumStream.listen((bands) {
      for (var i = 0; i < _bands; i++) {
        _target[i] = i < bands.length ? bands[i].clamp(0.0, 1.0) : 0.0;
      }
    });
    _playingSub = widget.player.playingStream.listen((p) => _playing = p);
    _playing = widget.player.isPlaying;
  }

  @override
  void dispose() {
    _specSub?.cancel();
    _playingSub?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  /// 每帧把显示幅值推向目标：播放中朝引擎值逼近（攻快放慢），
  /// 非播放态朝零衰减。
  void _step() {
    for (var i = 0; i < _bands; i++) {
      final goal = _playing ? _target[i] : 0.0;
      final k = goal > _display[i] ? 0.45 : 0.18;
      _display[i] += (goal - _display[i]) * k;
      if (_display[i] < 0.004) _display[i] = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ticker,
        builder: (context, _) {
          _step();
          return CustomPaint(
            size: Size(double.infinity, widget.height),
            painter: _SpectrumPainter(bands: _display, accent: accent),
          );
        },
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final List<double> bands;
  final Color accent;

  _SpectrumPainter({required this.bands, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final n = bands.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;
    const gap = 3.0;
    final barW = (size.width - gap * (n - 1)) / n;
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < n; i++) {
      // 静止时保留 2px 底线，视觉上是一条「基准线」而非空白
      final h = 2.0 + bands[i] * (size.height - 2.0);
      final x = i * (barW + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - h, barW, h),
        const Radius.circular(1.5),
      );
      // 幅值越高越亮：低幅值接近灰阶，高幅值趋向强调色——
      // 符合「黑白 UI + 内容带色」的设计哲学，安静时几乎隐形。
      final t = bands[i].clamp(0.0, 1.0);
      paint.color = Color.lerp(AppTheme.s4, accent, 0.25 + 0.75 * t)!
          .withValues(alpha: 0.35 + 0.65 * t);
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) => true;
}
