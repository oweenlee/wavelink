import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'cover_art.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;

/// 媒体网格卡：封面 + 标题 + 副标题（对齐 mobile 专辑/艺人网格卡）。
class MediaCard extends StatelessWidget {
  final String seed;
  final String? coverUrl;
  final double coverSize;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const MediaCard({
    super.key,
    required this.seed,
    this.coverUrl,
    required this.coverSize,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: coverSize,
              height: coverSize,
              child: CoverArt(
                key: ValueKey('card-$seed'),
                seed: seed,
                coverUrl: coverUrl,
                size: coverSize,
                rounded: true,
              ),
            ),
            const SizedBox(height: 7),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _onSurface, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _onSurfaceVariant, fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

/// 计算响应式网格列数与单元宽度（列数 2–8，基础单元格 180px）。
/// [hPad] 为 GridView 自身左右内边距之和（列表视图为 40，详情页专辑网格为 0），
/// 必须参与计算，否则 cellW 会大于 GridView 实际分配到的单元宽，导致卡片高于单元而溢出。
(int, double) gridMetrics(double maxWidth, {double hPad = 0}) {
  const gap = 16.0;
  final cols = ((maxWidth + gap) / (180 + gap)).floor().clamp(2, 8);
  final cellW = ((maxWidth - hPad) - gap * (cols - 1)) / cols;
  return (cols, cellW);
}
