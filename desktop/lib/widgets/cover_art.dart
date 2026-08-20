import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../services/cover.dart';
import '../services/cover_cache.dart';

/// 统一封面组件：优先显示真实封面图（对齐 mobile「内容带色」），
/// 无封面或加载失败时降级为确定性灰阶渐变占位。
///
/// [coverUrl] 同时支持本地缓存文件（[Image.file]，由封面提取管线写入）
/// 与远程地址（[Image.network]，如 Subsonic 直接提供的封面 URL）。
class CoverArt extends StatelessWidget {
  final String seed;
  final String? coverUrl;
  final double size;
  final bool rounded;
  const CoverArt({
    super.key,
    required this.seed,
    this.coverUrl,
    this.size = 48,
    this.rounded = true,
  });

  bool get _hasCover => coverUrl != null && coverUrl!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final radius = rounded ? size * 0.12 : 0.0;
    // 缩略图按展示尺寸解码缩放，避免大封面整图进内存（对齐 mobile cacheWidth 策略）
    final cacheWidth = (size * 2.5).round().clamp(128, 1024);
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: _hasCover
            ? _coverImage(radius, cacheWidth)
            : _gradientFallback(radius),
      ),
    );
  }

  Widget _coverImage(double radius, int cacheWidth) {
    final url = coverUrl!;
    final isRemote =
        url.startsWith('http://') || url.startsWith('https://');
    // 注意：cacheWidth 仅存在于 Image.file / Image.network 具名构造，
    // 默认 Image(image:) 构造不接受，故此处分别构造。
    final fallback = _gradientFallback(radius);
    final cacheW = cacheWidth;
    if (isRemote) {
      return Image.network(
        url,
        key: ValueKey(url),
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    final full = Image.file(
      File(url),
      key: ValueKey(url),
      fit: BoxFit.cover,
      cacheWidth: cacheW,
      errorBuilder: (_, _, _) => fallback,
    );
    // 小尺寸场景优先读 320px 缩略图（CoverCache 落盘 `<原图>.thumb.jpg`）：
    // 每行首显从整读 1~5MB 原图降为 ~30-60KB，千首曲库滚动不再磁盘峰值。
    // 缩略图缺失（老缓存/回填未完成）经 errorBuilder 回退原图显示。
    if (size <= CoverCache.thumbSize) {
      return Image.file(
        File(CoverCache.thumbPathFor(url)),
        key: ValueKey('thumb:$url'),
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        errorBuilder: (_, _, _) => full,
      );
    }
    return full;
  }

  Widget _gradientFallback(double radius) {
    final g = coverGradient(seed);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g,
        ),
      ),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: const RadialGradient(
                center: Alignment(-0.4, -0.5),
                radius: 0.9,
                colors: [Color(0x1AFFFFFF), Color(0x00000000)],
              ),
            ),
          ),
          Center(
            child: Icon(LucideIcons.music,
                color: Colors.white.withValues(alpha: 0.22),
                size: size * 0.4),
          ),
        ],
      ),
    );
  }
}
