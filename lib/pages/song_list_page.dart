import 'package:flutter/material.dart';
import 'package:wavelink_mobile/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/playback_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';

/// 通用歌曲列表页（用于「我喜欢的音乐」、已保存播放列表等）
class SongListPage extends StatelessWidget {
  final String title;
  final List<Song> songs;
  final Color accentColor;
  final bool isFavoriteList;

  const SongListPage({
    super.key,
    required this.title,
    required this.songs,
    this.accentColor = AppTheme.accentBlue,
    this.isFavoriteList = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();

    return Scaffold(
      backgroundColor: AppTheme.background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.chevron_left_rounded,
            color: AppTheme.textPrimary,
            size: 28,
          ),
          onPressed: () => Navigator.pop(context),
          splashRadius: 20,
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 60,
                bottom: 16,
              ),
              child: Column(
                children: [
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: 0.4),
                          blurRadius: 30,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Icon(
                        isFavoriteList
                            ? Icons.favorite_rounded
                            : Icons.playlist_play_rounded,
                        color: Colors.white.withValues(alpha: 0.85),
                        size: 48,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.songsCount(songs.length),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _RoundBtn(
                        icon: Icons.shuffle_rounded,
                        label: l10n.shufflePlay,
                        onTap: () {
                          if (songs.isEmpty) return;
                          player.toggleShuffle();
                          player.playAlbum(songs, startIndex: 0);
                          Navigator.pop(context);
                        },
                      ),
                      const SizedBox(width: 32),
                      _RoundBtn(
                        icon: Icons.play_arrow_rounded,
                        label: l10n.play,
                        filled: true,
                        onTap: () {
                          if (songs.isEmpty) return;
                          player.playAlbum(songs, startIndex: 0);
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  l10n.noSongs,
                  style: const TextStyle(fontSize: 15, color: AppTheme.textTertiary),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final song = songs[i];
                  final isPlaying =
                      player.isPlaying && player.currentSong?.id == song.id;
                  return SongTile(
                    song: song,
                    isPlaying: isPlaying,
                    onTap: () => player.playSong(song),
                    onMore: () => _showContextMenu(ctx, song, player),
                  );
                },
                childCount: songs.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  void _showContextMenu(
    BuildContext context,
    Song song,
    PlaybackProvider player,
  ) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded,
                  color: AppTheme.textPrimary),
              title: Text(l10n.play,
                  style: const TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                player.playSong(song);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.skip_next_rounded,
                  color: AppTheme.textPrimary),
              title: Text(l10n.playNext,
                  style: const TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                player.playNext(song);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded,
                  color: AppTheme.textPrimary),
              title: Text(l10n.addToQueue,
                  style: const TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                player.addToQueue(song);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(
                player.isSongFavorite(song.id)
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: AppTheme.danger,
              ),
              title: Text(
                player.isSongFavorite(song.id) ? l10n.unfavorite : l10n.favorite,
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () {
                player.setFavorite(song.id, !player.isSongFavorite(song.id));
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _RoundBtn({
    required this.icon,
    required this.label,
    this.filled = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: filled ? AppTheme.accentBlue : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: filled
                    ? AppTheme.accentBlue
                    : AppTheme.textTertiary.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
            child: Icon(
              icon,
              color: filled ? Colors.white : AppTheme.textPrimary,
              size: 26,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
