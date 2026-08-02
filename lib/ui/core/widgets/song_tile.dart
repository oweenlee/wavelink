import 'dart:io';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/material.dart';
import '../../../domain/models/song.dart';
import '../theme/app_theme.dart';
import 'album_cover.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final VoidCallback? onTap;
  final VoidCallback? onMore;
  final Widget? trailing;
  final int? trackNumber;

  const SongTile({
    super.key,
    required this.song,
    this.isPlaying = false,
    this.onTap,
    this.onMore,
    this.trailing,
    this.trackNumber,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: isPlaying
            ? BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: accent,
                    width: 2,
                  ),
                ),
                color: accent.withValues(alpha: 0.04),
              )
            : null,
        child: Row(
          children: [
            // Track number
            if (trackNumber != null) ...[
              SizedBox(
                width: 26,
                child: Text(
                  trackNumber.toString().padLeft(2, '0'),
                  textAlign: TextAlign.center,
                  style: WlText.mono(
                    fontSize: 12,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            // Album art
            _AlbumArt(song: song, isPlaying: isPlaying),
            const SizedBox(width: 12),
            // Title & artist
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isPlaying ? FontWeight.w600 : FontWeight.w400,
                      color: isPlaying ? accent : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} · ${song.album}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 格式标签 pill
            if (song.formatInfo != null) ...[
              _FormatBadge(song: song),
              const SizedBox(width: 6),
            ],
            // Duration
            Text(
              song.formattedDuration,
              style: WlText.mono(
                fontSize: 12,
                color: AppTheme.textTertiary,
              ),
            ),
            const SizedBox(width: 8),
            // 自定义 trailing（如收藏图标）
            if (trailing != null) ...[trailing!, const SizedBox(width: 4)],
            // More button
            GestureDetector(
              onTap: onMore,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  LucideIcons.moreHorizontal,
                  size: 20,
                  color: AppTheme.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 格式标签 pill：无损格式（FLAC/WAV/DSD 等）用 accent 高亮，有损格式用灰色
class _FormatBadge extends StatelessWidget {
  final Song song;
  const _FormatBadge({required this.song});

  @override
  Widget build(BuildContext context) {
    final fmt = song.formatInfo!;
    final isLossless = song.isLossless;
    final accent = AccentScope.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: isLossless
            ? accent.withValues(alpha: 0.12)
            : AppTheme.highlight,
        borderRadius: BorderRadius.circular(4),
        border: isLossless
            ? Border.all(color: accent.withValues(alpha: 0.3), width: 0.5)
            : null,
      ),
      child: Text(
        fmt,
        style: WlText.mono(
          fontSize: 9,
          color: isLossless ? accent : AppTheme.textTertiary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 专辑封面组件：有缓存封面则显示图片，否则显示纯色占位
class _AlbumArt extends StatelessWidget {
  final Song song;
  final bool isPlaying;

  const _AlbumArt({required this.song, required this.isPlaying});

  /// 获取封面缓存文件（coverUrl 优先，否则按 path hash 查找）
  File? _coverFile() {
    if (song.coverUrl != null) {
      final f = File(song.coverUrl!);
      if (f.existsSync()) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final coverFile = _coverFile();
    final hasCover = coverFile != null && coverFile.existsSync();

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: hasCover ? song.dominantColor : AppTheme.s2,
        borderRadius: BorderRadius.circular(8),
        border: hasCover
            ? null
            : Border.all(color: AppTheme.s4, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasCover
          ? Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  coverFile,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const CoverPlaceholder(size: 40),
                ),
                if (isPlaying)
                  Container(
                    color: Colors.black26,
                    child: const Center(child: _EqualizerBars()),
                  ),
              ],
            )
          : isPlaying
              ? const Center(child: _EqualizerBars())
              : const CoverPlaceholder(size: 40),
    );
  }
}

class _EqualizerBars extends StatefulWidget {
  const _EqualizerBars();

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final phase = i * 0.3;
            final h = 6 + (_controller.value + phase).abs() % 1.0 * 10;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                width: 2,
                height: h.clamp(4.0, 16.0),
                decoration: BoxDecoration(
                  color: AccentScope.of(context),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
