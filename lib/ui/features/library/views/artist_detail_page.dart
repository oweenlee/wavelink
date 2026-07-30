import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../../../domain/models/song.dart';
import '../../playback/view_models/playback_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/now_playing_indicator.dart';

class ArtistDetailPage extends StatelessWidget {
  final String artistName;
  final Color artistColor;
  const ArtistDetailPage({
    super.key,
    required this.artistName,
    required this.artistColor,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final songs = player.allSongs.where((s) => s.artist == artistName).toList();
    final albums = songs.map((s) => s.album).toSet().toList();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.8),
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
        title: Text(
          artistName,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Column(
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: artistColor,
                      borderRadius: BorderRadius.circular(50),
                    ),
                    child: Center(
                      child: Text(
                        artistName.isNotEmpty ? artistName[0] : '?',
                        style: const TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    artistName,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.artistSongsAlbums(songs.length, albums.length),
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _ActionButton(
                    icon: Icons.shuffle_rounded,
                    label: l10n.shuffleAll,
                    onTap: () {
                      final shuffled = List<Song>.from(songs)..shuffle();
                      player.playAlbum(shuffled);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
          for (final album in albums) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                child: Text(
                  album,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((ctx, i) {
                final ss = songs.where((s) => s.album == album).toList();
                final s = ss[i];
                final isCurrent =
                    player.isPlaying && player.currentSong?.id == s.id;
                return _TrackTile(
                  song: s,
                  isCurrent: isCurrent,
                  onTap: () {
                    final allSongs = songs
                        .where((x) => x.album == album)
                        .toList();
                    player.playAlbum(allSongs, startIndex: i);
                    Navigator.pop(context);
                  },
                );
              }, childCount: songs.where((s) => s.album == album).length),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;
  const _TrackTile({
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
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: song.dominantColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: isCurrent
                  ? const Center(
                      child: NowPlayingIndicator(
                        baseHeight: 4,
                        barScale: 8,
                        maxHeight: 12,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: isCurrent ? AppTheme.brand : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.album,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (song.bpm != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${song.bpm} BPM',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textTertiary,
                  ),
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

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.brand.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppTheme.brand, size: 20),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.brand,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
