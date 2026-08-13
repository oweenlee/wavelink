import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/song.dart';
import '../../playback/view_models/playback_controller.dart';
import '../../playback/view_models/audio_player_provider.dart';
import '../../playback/view_models/queue_provider.dart';
import '../view_models/library_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/album_cover.dart';

class ArtistDetailPage extends ConsumerWidget {
  final String artistName;
  final Color artistColor;
  const ArtistDetailPage({
    super.key,
    required this.artistName,
    required this.artistColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    // 只 select isPlaying：避免 250ms 进度 tick 触发整页重建
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final queueState = ref.watch(queueProvider);
    ref.watch(libraryProvider);
    final songs = player.allSongs.where((s) => s.artist == artistName).toList();
    // 按专辑分组（单次 O(N) 遍历，避免逐专辑 where 扫描）
    final albumMap = <String, List<Song>>{};
    for (final s in songs) {
      (albumMap[s.album] ??= []).add(s);
    }
    final albums = albumMap.keys.toList();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.8),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            LucideIcons.chevronLeft,
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
                  WlCover(
                    coverUrl: songs.isNotEmpty ? songs.first.coverUrl : null,
                    fallbackColor: artistColor,
                    borderRadius: 50,
                    width: 100,
                    height: 100,
                    placeholder: Center(
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
                    icon: LucideIcons.shuffle,
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
                final ss = albumMap[album]!;
                final s = ss[i];
                final isCurrent = queueState.currentSong?.id == s.id;
                return _TrackTile(
                  song: s,
                  isCurrent: isCurrent,
                  isPlaying: isPlaying && isCurrent,
                  onTap: () {
                    player.playAlbum(ss, startIndex: i);
                    Navigator.pop(context);
                  },
                );
              }, childCount: albumMap[album]!.length),
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
  final bool isPlaying;
  final VoidCallback onTap;
  const _TrackTile({
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
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
            // 行内封面：有图显示图，否则纯色占位；当前播放叠加指示器
            SongCoverArt(song: song, isCurrent: isCurrent, isPlaying: isPlaying),
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
                  // 专辑解析不到（占位文案）则不显示专辑行
                  if (song.displayAlbum != null)
                    Text(
                      song.displayAlbum!,
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
