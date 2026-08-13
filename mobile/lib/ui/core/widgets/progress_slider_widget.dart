import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ProgressSliderWidget extends StatelessWidget {
  final double progress;
  final double? buffered;
  final String current;
  final String total;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onDragging;
  final ValueChanged<double>? onDragStart;
  final ValueChanged<double>? onChangeEnd;

  const ProgressSliderWidget({
    super.key,
    required this.progress,
    this.buffered,
    required this.current,
    required this.total,
    required this.onChanged,
    this.onDragging,
    this.onDragStart,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    // 时间标签/进度条/滑块统一灰系（textSecondary），与控制按钮同色；
    // 避免封面主色（如纯红）在进度区大面积刺眼
    const trackColor = AppTheme.textSecondary;
    // 时间标签左右夹滑块：经典播放器布局，比“滑块+下方标签”省一行垂直空间
    return Row(
      children: [
        Text(
          current,
          style: WlText.mono(
            fontSize: 10,
            color: trackColor,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: _ThumbShape(Colors.white),
              activeTrackColor: Colors.white,
              inactiveTrackColor: AppTheme.textTertiary.withValues(alpha: 0.3),
              overlayColor: Colors.white.withValues(alpha: 0.1),
            ),
            child: Slider(
              value: progress.clamp(0.0, 1.0),
              onChangeStart: onDragStart,
              onChanged: (v) {
                onChanged(v);
                onDragging?.call(v);
              },
              onChangeEnd: onChangeEnd == null
                  ? null
                  : (v) {
                      onChangeEnd?.call(v);
                    },
            ),
          ),
        ),
        Text(
          total,
          style: WlText.mono(
            fontSize: 10,
            color: trackColor,
          ),
        ),
      ],
    );
  }
}

class _ThumbShape extends SliderComponentShape {
  final Color color;
  _ThumbShape(this.color);

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(16, 16);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final radius = activationAnimation.value * 4 + 8;

    // Glow
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.2 * activationAnimation.value)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(center, radius + 4, glowPaint);

    // Thumb
    final thumbPaint = Paint()..color = color;
    canvas.drawCircle(center, radius, thumbPaint);

    // Inner highlight
    final innerPaint = Paint()..color = Colors.white.withValues(alpha: 0.4);
    canvas.drawCircle(center - const Offset(1, 1), radius * 0.4, innerPaint);
  }
}
