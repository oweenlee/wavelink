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

class _AlbumCoverState extends State<AlbumCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tiltCtrl;
  late Animation<double> _tiltX;
  late Animation<double> _tiltY;
  // 封面是整棵子树最重的部分，构建一次缓存，手势/回弹只重绘 transform 层；
  // 切歌（coverUrl/color 变化）时在 didUpdateWidget 重建
  late WlCover _cover;

  @override
  void initState() {
    super.initState();
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _tiltX = Tween(begin: 0.0, end: 0.0).animate(_tiltCtrl);
    _tiltY = Tween(begin: 0.0, end: 0.0).animate(_tiltCtrl);
    // 封面是整棵子树最重的部分，构建一次缓存，手势/回弹只重绘 transform 层
    _cover = WlCover(
      coverUrl: widget.coverUrl,
      fallbackColor: widget.color,
      borderRadius: 20,
    );
  }

  @override
  void didUpdateWidget(covariant AlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.coverUrl != oldWidget.coverUrl || widget.color != oldWidget.color) {
      _cover = WlCover(
        coverUrl: widget.coverUrl,
        fallbackColor: widget.color,
        borderRadius: 20,
      );
    }
  }

  @override
  void dispose() {
    _tiltCtrl.dispose();
    super.dispose();
  }

  void _onPanUpdate(Offset local, double size) {
    final x = ((local.dx - size / 2) / size * 0.06).clamp(-0.03, 0.03);
    final y = ((local.dy - size / 2) / size * 0.06).clamp(-0.03, 0.03);
    // 从当前值平滑追向手指，由 controller 驱动重建，避免 setState 整树重绘
    _tiltX = Tween(begin: _tiltX.value, end: x).animate(_tiltCtrl);
    _tiltY = Tween(begin: _tiltY.value, end: y).animate(_tiltCtrl);
    _tiltCtrl.forward(from: 0);
  }

  void _onPanEnd() {
    _tiltX = Tween(begin: _tiltX.value, end: 0.0).animate(
      CurvedAnimation(parent: _tiltCtrl, curve: Curves.easeOutBack),
    );
    _tiltY = Tween(begin: _tiltY.value, end: 0.0).animate(
      CurvedAnimation(parent: _tiltCtrl, curve: Curves.easeOutBack),
    );
    _tiltCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.5;
    final cover = SizedBox(width: size, height: size, child: _cover);

    return GestureDetector(
      onPanUpdate: (d) => _onPanUpdate(d.localPosition, size),
      onPanEnd: (_) => _onPanEnd(),
      child: AnimatedBuilder(
        animation: _tiltCtrl,
        builder: (context, child) => Transform(
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateX(_tiltY.value)
            ..rotateY(_tiltX.value),
          child: child,
        ),
        child: cover,
      ),
    );
  }
}
