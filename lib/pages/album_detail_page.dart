import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/playback_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/now_playing_indicator.dart';

class AlbumDetailPage extends StatelessWidget {
  final Album album;
  const AlbumDetailPage({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
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
        actions: [
          IconButton(
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: AppTheme.textPrimary,
            ),
            onPressed: () {},
            splashRadius: 20,
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // cover
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 60,
                bottom: 24,
              ),
              child: Column(
                children: [
                  _AlbumCover(album: album),
                  const SizedBox(height: 20),
                  _AlbumInfo(album: album, player: player),
                  const SizedBox(height: 16),
                  _ActionButtons(
                    onPlayAll: () {
                      player.playAlbum(album.songs);
                      Navigator.pop(context);
                    },
                    onShuffle: () {
                      final shuffled = List<Song>.from(album.songs)..shuffle();
                      player.playAlbum(shuffled);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
          // track list
          SliverList(
            delegate: SliverChildBuilderDelegate((ctx, i) {
              final s = album.songs[i];
              final isCurrent =
                  player.isPlaying && player.currentSong?.id == s.id;
              return _TrackTile(
                index: i + 1,
                song: s,
                isCurrent: isCurrent,
                onTap: () {
                  player.playAlbum(album.songs, startIndex: i);
                  Navigator.pop(context);
                },
              );
            }, childCount: album.songs.length),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}

class _AlbumCover extends StatelessWidget {
  final Album album;
  const _AlbumCover({required this.album});

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.35;
    final w = MediaQuery.of(context).size.width * 0.6;
    return Center(
      child: Container(
        width: w,
        height: h.clamp(240.0, 320.0),
        decoration: BoxDecoration(
          color: album.dominantColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: album.dominantColor.withValues(alpha: 0.35),
              blurRadius: 40,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Center(
          child: Icon(
            Icons.album_rounded,
            color: Colors.white.withValues(alpha: 0.25),
            size: 80,
          ),
        ),
      ),
    );
  }
}

class _AlbumInfo extends StatelessWidget {
  final Album album;
  final PlaybackProvider player;
  const _AlbumInfo({required this.album, required this.player});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final analysis = player.getAnalysis(album.songs.first.id);
    final bpm = analysis?.bpm;
    final key = analysis?.key;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            album.title,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '${album.artist} · ${album.year} · ${l10n.songsCount(album.songs.length)} · ${album.formattedDurationOf(l10n)}',
            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
            textAlign: TextAlign.center,
          ),
          if (bpm != null || key != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (bpm != null) _Tag(label: '${bpm.round()} BPM'),
                if (key != null) _Tag(label: key),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  const _Tag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  const _ActionButtons({required this.onPlayAll, required this.onShuffle});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onPlayAll,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  color: AppTheme.accentBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.accentBlue.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      color: AppTheme.accentBlue,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.playAll,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.accentBlue,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: onShuffle,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  color: AppTheme.accentPurple.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.accentPurple.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.shuffle_rounded,
                      color: AppTheme.accentPurple,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.shufflePlay,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.accentPurple,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final int index;
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;
  const _TrackTile({
    required this.index,
    required this.song,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: isCurrent
                  ? const NowPlayingIndicator(
                      baseHeight: 4, barScale: 8, maxHeight: 12,
                    )
                  : Text(
                      '$index',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textTertiary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: isCurrent
                          ? AppTheme.accentBlue
                          : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              song.formattedDuration,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


