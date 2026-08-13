import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/material.dart';
import '../../../domain/models/song.dart';
import '../theme/app_theme.dart';
import 'album_cover.dart';

class SongTile extends StatelessWidget {
  final Song song;

  /// 是否为当前曲目（选择态：暂停也保留高亮）。
  final bool isCurrent;

  /// 是否正在播放（驱动封面上的跳动指示器动画）。
  final bool isPlaying;

  final VoidCallback? onTap;
  final VoidCallback? onMore;
  final Widget? trailing;
  final int? trackNumber;

  const SongTile({
    super.key,
    required this.song,
    this.isCurrent = false,
    this.isPlaying = false,
    this.onTap,
    this.onMore,
    this.trailing,
    this.trackNumber,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    // opaque：整个行区域（含文字/封面的空白间隙）都可点，
    // 裸 GestureDetector（deferToChild）只有实际渲染元素响应
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: isCurrent
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
            SongCoverArt(song: song, isCurrent: isCurrent, isPlaying: isPlaying),
            const SizedBox(width: 8),
            // Title & artist
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isCurrent
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: isCurrent ? accent : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // 来源图标始终保留；副标题（艺术家 · 专辑）解析不到的部分不显示
                  Row(
                    children: [
                      Icon(
                        _sourceIcon(song.source),
                        size: 12,
                        color: AppTheme.textTertiary,
                      ),
                      if (song.artistAlbumLine.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            song.artistAlbumLine,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
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
            // 自定义 trailing（如收藏图标）
            if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
            // 仅当传入 onMore 时才显示「更多」按钮（三个小点）；
            // 不传则不渲染，调用方据此控制是否在列表中暴露该菜单
            if (onMore != null) ...[
              const SizedBox(width: 8),
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

/// 来源图标映射：NAS=硬盘、Apple Music 同步=苹果、Subsonic=服务器、文件导入=文件夹（与导入弹窗 Pick Files 一致）、本地媒体库=音乐
IconData _sourceIcon(SongSource source) => switch (source) {
      SongSource.nas => LucideIcons.hardDrive,
      SongSource.appleMusic => LucideIcons.apple,
      SongSource.subsonic => LucideIcons.server,
      SongSource.imported => LucideIcons.folderOpen,
      SongSource.local => LucideIcons.music,
    };
