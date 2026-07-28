import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/playback/view_models/playback_provider.dart';
import '../theme/app_theme.dart';

/// 实时频谱可视化（16 频段）。轮询 Rust 端 getSpectrum()，不依赖平台事件通道。
class SpectrumBar extends StatefulWidget {
  final double height;

  const SpectrumBar({super.key, this.height = 120});

  @override
  State<SpectrumBar> createState() => _SpectrumBarState();
}

class _SpectrumBarState extends State<SpectrumBar> {
  List<double> _bars = List.filled(16, 0.0);
  final List<double> _smoothed = List.filled(16, 0.0);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final player = context.read<PlaybackProvider>();
    player.getSpectrum().then((data) {
      if (!mounted) return;
      for (var i = 0; i < _smoothed.length; i++) {
        final v = data.length > i ? data[i] : 0.0;
        _smoothed[i] = v > _smoothed[i] ? v : _smoothed[i] * 0.7 + v * 0.3;
      }
      setState(() => _bars = List.from(_smoothed));
    });
    _timer = Timer(const Duration(milliseconds: 50), _tick);
  }

  @override
  Widget build(BuildContext context) {
    const barColor = AppTheme.accentBlue;
    return SizedBox(
      height: widget.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_bars.length, (i) {
          final h = (_bars[i].clamp(0.0, 1.0) * widget.height).clamp(2.0, widget.height);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                height: h,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      barColor.withValues(alpha: 0.15),
                      barColor.withValues(alpha: 0.9),
                    ],
                  ),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  boxShadow: [
                    BoxShadow(
                      color: barColor.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: Offset.zero,
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
