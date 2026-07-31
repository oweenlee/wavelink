import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class AlbumCover extends StatefulWidget {
  final Color color;

  const AlbumCover({super.key, required this.color});

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
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5),
                blurRadius: 40,
                spreadRadius: 5,
                offset: Offset(_tiltX * 200, _tiltY * 200),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              LucideIcons.music,
              color: Colors.white.withValues(alpha: 0.2),
              size: size * 0.3,
            ),
          ),
        ),
      ),
    );
  }
}
