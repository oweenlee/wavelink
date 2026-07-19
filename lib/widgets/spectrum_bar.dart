import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/playback_provider.dart';

/// 实时频谱可视化（16 频段）。轮询 Rust 端 getSpectrum()，不依赖平台事件通道。
class SpectrumBar extends StatefulWidget {
  final double height;
  final Color color;

  const SpectrumBar({super.key, this.height = 120, this.color = Colors.white});

  @override
  State<SpectrumBar> createState() => _SpectrumBarState();
}

class _SpectrumBarState extends State<SpectrumBar> {
  List<double> _bars = List.filled(16, 0.0);
  final List<double> _smoothed = List.filled(16, 0.0);

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    if (!mounted) return;
    final player = context.read<PlaybackProvider>();
    player.getSpectrum().then((data) {
      if (!mounted) return;
      for (var i = 0; i < _smoothed.length; i++) {
        final v = data.length > i ? data[i] : 0.0;
        // 平滑：上升即时、下降缓慢
        _smoothed[i] = v > _smoothed[i] ? v : _smoothed[i] * 0.7 + v * 0.3;
      }
      setState(() => _bars = List.from(_smoothed));
    });
    Future.delayed(const Duration(milliseconds: 50), _tick);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_bars.length, (i) {
          final h = (_bars[i].clamp(0.0, 1.0) * widget.height).clamp(2.0, widget.height);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                height: h,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
