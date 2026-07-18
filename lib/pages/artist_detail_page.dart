import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/playback_provider.dart';
import '../theme/app_theme.dart';

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
                    '${songs.length} 首歌曲 · ${albums.length} 张专辑',
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _ActionButton(
                    icon: Icons.shuffle_rounded,
                    label: '随机播放全部',
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
                  ? const Center(child: _NowPlayingIndicator())
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
                      color: isCurrent
                          ? AppTheme.accentBlue
                          : AppTheme.textPrimary,
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
          color: AppTheme.accentPurple.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppTheme.accentPurple.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppTheme.accentPurple, size: 20),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.accentPurple,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingIndicator extends StatefulWidget {
  const _NowPlayingIndicator();
  @override
  State<_NowPlayingIndicator> createState() => _NowPlayingIndicatorState();
}

class _NowPlayingIndicatorState extends State<_NowPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ac;
  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (_, _) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(3, (i) {
          final h = 4 + (_ac.value + i * 0.3) % 1.0 * 8;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 2,
              height: h.clamp(4.0, 12.0),
              decoration: BoxDecoration(
                color: AppTheme.accentBlue,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}
