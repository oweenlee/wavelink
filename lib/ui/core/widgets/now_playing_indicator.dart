import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
  late AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (_, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(3, (i) {
          final h = widget.baseHeight + (_ac.value + i * 0.3) % 1.0 * widget.barScale;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 2,
              height: h.clamp(widget.minHeight, widget.maxHeight),
              decoration: BoxDecoration(
                color: AppTheme.accentBlue,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}
