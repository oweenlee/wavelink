import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme/app_theme.dart';

/// 统一封面组件：优先显示真实封面图（coverUrl），无图时降级为精致色块。
/// 用于专辑网格、艺人头像、播放列表缩略图、MiniPlayer、详情页大封面等，
/// 让"内容带色"的设计意图（真实彩色封面）在整个 App 一致呈现。
class WlCover extends StatelessWidget {
  final String? coverUrl;
  final Color fallbackColor;
  final double borderRadius;
  final double? width;
  final double? height;
  final Widget? overlay; // 叠加层（NOW 角标、均衡器等）
  final Widget? placeholder; // 自定义降级占位（首字母 / 图标）

  const WlCover({
    super.key,
    this.coverUrl,
    required this.fallbackColor,
    this.borderRadius = 10,
    this.width,
    this.height,
    this.overlay,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    final hasCover = coverUrl != null && coverUrl!.isNotEmpty;
    final radius = BorderRadius.circular(borderRadius);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: hasCover ? fallbackColor : AppTheme.s2,
        borderRadius: radius,
        boxShadow: hasCover
            ? [
                BoxShadow(
                  color: fallbackColor.withValues(alpha: 0.3),
                  blurRadius: 20,
                  spreadRadius: 1,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasCover)
              Image.file(
                File(coverUrl!),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => _fallback(),
              )
            else
              _fallback(),
            if (overlay != null) overlay!,
          ],
        ),
      ),
    );
  }

  Widget _fallback() {
    return placeholder ?? CoverPlaceholder(size: width);
  }
}

/// 封面占位图：黑胶唱片风格。
/// 外层细圆环 + 内圈填充 + 中心音符图标，放在 s2 底 + s4 边框容器内。
class CoverPlaceholder extends StatelessWidget {
  final double? size;
  const CoverPlaceholder({super.key, this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.s2,
        border: Border.all(color: AppTheme.s4, width: 0.5),
      ),
      child: Center(
        child: CustomPaint(
          size: Size.square((size ?? 80) * 0.52),
          painter: _VinylPainter(),
          child: SizedBox.expand(
            child: Center(
              child: Icon(
                LucideIcons.disc3,
                color: AppTheme.textTertiary.withValues(alpha: 0.35),
                size: (size ?? 80) * 0.16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 黑胶唱片同心圆纹理
class _VinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2, cy = s.height / 2;
    final base = math.min(cx, cy);

    // 外圈细环
    final outer = Paint()
      ..color = AppTheme.s4
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(Offset(cx, cy), base, outer);

    // 内圈填充
    final inner = Paint()
      ..color = AppTheme.s3
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), base * 0.55, inner);

    // 最内圈细环
    final ring = Paint()
      ..color = AppTheme.s4
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    canvas.drawCircle(Offset(cx, cy), base * 0.55, ring);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class AlbumCover extends StatefulWidget {
  final Color color;
  final String? coverUrl;

  const AlbumCover({super.key, required this.color, this.coverUrl});

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover> {
  double _tiltX = 0, _tiltY = 0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.5;

    return GestureDetector(
      onPanUpdate: (d) {
        setState(() {
          _tiltX = ((d.localPosition.dx - size / 2) / size * 0.06).clamp(
            -0.03,
            0.03,
          );
          _tiltY = ((d.localPosition.dy - size / 2) / size * 0.06).clamp(
            -0.03,
            0.03,
          );
        });
      },
      onPanEnd: (_) => setState(() {
        _tiltX = 0;
        _tiltY = 0;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateX(_tiltY)
          ..rotateY(_tiltX),
        child: WlCover(
          coverUrl: widget.coverUrl,
          fallbackColor: widget.color,
          borderRadius: 20,
          width: size,
          height: size,
        ),
      ),
    );
  }
}
