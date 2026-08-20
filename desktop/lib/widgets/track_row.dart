import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../core/theme.dart';
import '../core/format.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';
import 'cover_art.dart';
import 'dialogs.dart';
import 'now_playing_indicator.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

/// 歌曲行（对齐 mobile `ui/core/widgets/song_tile.dart` 的 SongTile）：
/// 封面（当前曲目叠加播放指示器遮罩）+ 标题/艺术家 + 时长 + 来源徽章 +
/// 收藏 + 更多菜单。
class TrackRow extends StatelessWidget {
  final PlayerController player;
  final Track track;
  final int index;

  /// 是否为当前曲目（选择态：暂停也保留高亮与遮罩，对齐 mobile 语义）。
  final bool isCurrent;

  /// 是否正在播放（驱动封面上的跳动指示器动画）。
  final bool isPlaying;

  final ValueChanged<int> onPlay;

  const TrackRow({
    super.key,
    required this.player,
    required this.track,
    required this.index,
    this.isCurrent = false,
    this.isPlaying = false,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final l10n = AppLocalizations.of(context);
    final badge = track.isCueTrack
        ? 'CUE'
        : track.isNetwork
            ? track.source.short
            : (track.filePath != null
                ? p.extension(track.filePath!)
                    .toUpperCase()
                    .replaceFirst('.', '')
                : l10n.simulated);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onPlay(index),
        child: Container(
          decoration: isCurrent
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(color: accent, width: 2),
                  ),
                  color: accent.withValues(alpha: 0.05),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              children: [
                _TrackCover(
                  track: track,
                  isCurrent: isCurrent,
                  isPlaying: isPlaying,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: isCurrent ? accent : _onSurface,
                              fontSize: 13.5,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(sourceIcon(track.source),
                              size: 12, color: AppTheme.textTertiary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _onSurfaceVariant, fontSize: 12)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              // 标签扫描期读到的真实时长（网络曲为扫描回填；未知不显示）
              if (track.durationHint != null &&
                  track.durationHint! > Duration.zero) ...[
                Text(fmtDuration(track.durationHint!),
                    style: WlText.mono(
                        fontSize: 10.5, color: AppTheme.textTertiary)),
                const SizedBox(width: 10),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: _border),
                ),
                child: Text(badge,
                    style: WlText.mono(
                        fontSize: 9.5,
                        color: _onSurfaceVariant,
                        fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 10),
              _FavoriteButton(player: player, track: track),
              PopupMenuButton<String>(
                icon: const Icon(LucideIcons.moreVertical,
                    size: 18, color: AppTheme.textTertiary),
                color: _surface,
                itemBuilder: (c) => [
                  PopupMenuItem(
                    value: 'fav',
                    child: Text(
                        player.isFavorite(track) ? l10n.favRemove : l10n.favAdd,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                  PopupMenuItem(
                    value: 'next',
                    child: Text(l10n.playNext,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                  PopupMenuItem(
                    value: 'add',
                    child: Text(l10n.addToPlaylist,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                  PopupMenuItem(
                    value: 'play',
                    child: Text(l10n.playNow,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                ],
                onSelected: (v) {
                  switch (v) {
                    case 'fav':
                      player.toggleFavorite(track);
                    case 'next':
                      player.playNext(track);
                    case 'add':
                      showAddToPlaylistDialog(context, player, track);
                    case 'play':
                      onPlay(index);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// 行内封面：当前曲目叠加播放状态遮罩（对齐 mobile SongCoverArt）——
/// 播放中 = 半透明黑遮罩 + 跳动均衡器；暂停 = 遮罩 + 静态暂停图标。
class _TrackCover extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final bool isPlaying;

  const _TrackCover({
    required this.track,
    required this.isCurrent,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    final cover = CoverArt(
      key: ValueKey('row-${track.coverUrl ?? track.id}'),
      seed: track.id,
      coverUrl: track.coverUrl,
      size: 42,
    );
    if (!isCurrent) return cover;
    return Stack(
      alignment: Alignment.center,
      children: [
        cover,
        // 遮罩放在 ClipRRect 之外会溢出圆角，这里用同尺寸容器裁剪
        ClipRRect(
          borderRadius: BorderRadius.circular(42 * 0.12),
          child: Container(
            width: 42,
            height: 42,
            color: Colors.black26,
            alignment: Alignment.center,
            child: isPlaying
                ? const NowPlayingIndicator(baseHeight: 4, barScale: 6)
                : Icon(Icons.pause,
                    size: 14, color: AccentScope.of(context)),
          ),
        ),
      ],
    );
  }
}

class _FavoriteButton extends ConsumerWidget {
  final PlayerController player;
  final Track track;
  const _FavoriteButton({required this.player, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(favoritesProvider);
    final fav = player.isFavorite(track);
    return IconButton(
      icon: Icon(
        fav ? LucideIcons.heart : LucideIcons.heart,
        size: 17,
        color: fav ? AppTheme.danger : AppTheme.textTertiary,
        fill: fav ? 1.0 : 0.0,
      ),
      onPressed: () => player.toggleFavorite(track),
    );
  }
}

/// 来源图标映射（对齐 mobile SongTile._sourceIcon）：
/// NAS=硬盘、WebDAV=云、Subsonic=服务器、本地=音乐。
IconData sourceIcon(TrackSource source) => switch (source) {
      TrackSource.nas => LucideIcons.hardDrive,
      TrackSource.webdav => LucideIcons.cloud,
      TrackSource.subsonic => LucideIcons.server,
      TrackSource.local => LucideIcons.music,
    };
