import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../domain/models/song.dart';
import '../../playback/view_models/playback_provider.dart';
import '../view_models/library_header_notifier.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../core/widgets/album_cover.dart';


class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final headerNotifier = context.watch<LibraryHeaderNotifier>();

    return Column(
      children: [
        // ── Search bar (toggled from AppShell top-right icon) ──
        if (headerNotifier.isSearchVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.s2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (v) => headerNotifier.setQuery(v.toLowerCase()),
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                  fontFamily: 'Inter',
                ),
                cursorColor: AppTheme.accentFallback,
                decoration: InputDecoration(
                  prefixIcon: const Icon(
                    LucideIcons.search,
                    size: 16,
                    color: AppTheme.textTertiary,
                  ),
                  hintText: l10n.searchLibrary,
                  hintStyle: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.textTertiary,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),

        // ── Segmented tab control ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.s2,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(2),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: AppTheme.s4,
                borderRadius: BorderRadius.circular(6),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: AppTheme.textPrimary,
              unselectedLabelColor: AppTheme.textTertiary,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 12),
              tabs: [
                Tab(text: l10n.libSongs),
                Tab(text: l10n.libAlbums),
                Tab(text: l10n.libArtists),
                Tab(text: l10n.libPlaylists),
              ],
              onTap: (_) {
                // Close search when switching tabs
                if (headerNotifier.isSearchVisible) {
                  headerNotifier.closeSearch();
                  _searchController.clear();
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),

        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _SongsTab(),
              _AlbumsTab(),
              _ArtistsTab(),
              _PlaylistsTab(),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Empty State ──

class _EmptyLibrary extends StatelessWidget {
  final String message;
  const _EmptyLibrary({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.library,
              size: 64,
              color: AppTheme.textTertiary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                fontSize: 15,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Songs Tab ──

class _SongsTab extends StatelessWidget {
  const _SongsTab();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final headerNotifier = context.watch<LibraryHeaderNotifier>();
    final allSongs = player.allSongs;

    final query = headerNotifier.searchQuery;
    final displayed = query.isEmpty
        ? allSongs
        : allSongs
            .where((s) =>
                s.title.toLowerCase().contains(query) ||
                s.artist.toLowerCase().contains(query) ||
                s.album.toLowerCase().contains(query))
            .toList();

    if (displayed.isEmpty) {
      return _EmptyLibrary(
        message: query.isNotEmpty ? l10n.noSongs : l10n.noMusicHint,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: displayed.length,
      itemBuilder: (context, index) {
        final song = displayed[index];
        final isPlaying =
            player.isPlaying && player.currentSong?.id == song.id;
        return SongTile(
          song: song,
          isPlaying: isPlaying,
          trackNumber: allSongs.indexOf(song) + 1,
          onTap: () => player.playSong(song),
          onMore: () => _showContextMenu(context, song, player),
          trailing: player.isSongFavorite(song.id)
              ? const Icon(
                  LucideIcons.heart,
                  size: 16,
                  color: AppTheme.danger,
                )
              : null,
        );
      },
    );
  }
}

// ── Albums Tab ──

class _AlbumsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final songs = player.allSongs;

    // group by album
    final albumNames = songs.map((s) => s.album).toSet().toList();
    if (albumNames.isEmpty) {
      return _EmptyLibrary(message: l10n.noAlbumInfo);
    }

    return GridView.builder(
      padding: const EdgeInsets.only(
        bottom: 80,
        left: 16,
        right: 16,
        top: 8,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.72,
      ),
      itemCount: albumNames.length,
      itemBuilder: (context, index) {
        final name = albumNames[index];
        final albumSongs = songs.where((s) => s.album == name).toList();
        final color = albumSongs.first.dominantColor;
        final isPlayingAlbum =
            player.currentSong?.album == name && player.isPlaying;

        return GestureDetector(
          onTap: () => context.push(
            '/album',
            extra: Album(
              id: name,
              title: name,
              artist: albumSongs.first.artist,
              year: 0,
              songs: albumSongs,
              dominantColor: color,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Album artwork
              Expanded(
                child: WlCover(
                  coverUrl: albumSongs.first.coverUrl,
                  fallbackColor: color,
                  borderRadius: 10,
                  width: double.infinity,
                  height: double.infinity,
                  overlay: isPlayingAlbum
                      ? Align(
                          alignment: Alignment.bottomRight,
                          child: Container(
                            margin: const EdgeInsets.all(8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accentFallback,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'NOW',
                              style: WlText.mono(
                                fontSize: 9,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              // Album title
              Text(
                name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              // Mono meta line
              Text(
                '${albumSongs.length} songs',
                style: WlText.mono(
                  fontSize: 11,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Artists Tab ──

class _ArtistsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final songs = player.allSongs;

    final artistNames = songs.map((s) => s.artist).toSet().toList();
    if (artistNames.isEmpty) {
      return _EmptyLibrary(message: l10n.noArtistInfo);
    }

    return CustomScrollView(
      slivers: [
        // Shuffle All pill
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (songs.isNotEmpty) {
                      player.playSong(songs.first);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.s3,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.shuffle,
                          size: 14,
                          color: AppTheme.textPrimary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.shuffleAll,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${artistNames.length} artists',
                  style: WlText.mono(
                    fontSize: 11,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Artist list
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final name = artistNames[index];
              final artistSongs = songs.where((s) => s.artist == name).toList();
              final count = artistSongs.length;
              final albumCount =
                  artistSongs.map((s) => s.album).toSet().length;
              final artistColor = artistSongs.first.dominantColor;

              return GestureDetector(
                onTap: () => context.push(
                  '/artist',
                  extra: {'name': name, 'color': artistColor},
                ),
                child: Container(
                  margin: const EdgeInsets.only(
                    bottom: 12,
                    left: 16,
                    right: 16,
                  ),
                  child: Row(
                    children: [
                      WlCover(
                        coverUrl: artistSongs.first.coverUrl,
                        fallbackColor: artistColor,
                        borderRadius: 24,
                        width: 48,
                        height: 48,
                        placeholder: Center(
                          child: Text(
                            name.isNotEmpty ? name[0] : '?',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              l10n.artistSongsAlbums(count, albumCount),
                              style: WlText.mono(
                                fontSize: 11,
                                color: AppTheme.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        LucideIcons.chevronRight,
                        color: AppTheme.textTertiary,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              );
            },
            childCount: artistNames.length,
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }
}

// ── Playlists Tab ──

class _PlaylistsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final favorites = player.favoriteSongs;
    final saved = player.playlists;

    // "我喜欢的音乐" 固定在最前，其余为已保存播放列表
    final entries = <_PlaylistEntry>[
      _PlaylistEntry(
        name: l10n.favMusic,
        count: favorites.length,
        color: AppTheme.danger,
        songs: favorites,
        builtIn: true,
      ),
      ...saved.entries.map(
        (e) => _PlaylistEntry(
          name: e.key,
          count: e.value.length,
          color: AppTheme.brand,
          songs: player.playlistSongs(e.key),
        ),
      ),
    ];

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80, left: 16, right: 16, top: 8),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                // New Playlist
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showCreatePlaylist(context, player),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.s3,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            LucideIcons.plus,
                            color: AppTheme.textPrimary,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.newPlaylist,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Import/Export
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showComingSoon(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.s2,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppTheme.s4,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            LucideIcons.download,
                            color: AppTheme.textSecondary,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'M3U · PLS',
                            style: WlText.mono(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
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

        final pl = entries[index - 1];
        return GestureDetector(
          onTap: () => context.push(
            '/song-list',
            extra: {
              'title': pl.name,
              'songs': pl.songs,
              'accentColor': pl.color,
              'isFavoriteList': pl.builtIn,
            },
          ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                WlCover(
                  coverUrl: pl.songs.isNotEmpty ? pl.songs.first.coverUrl : null,
                  fallbackColor: pl.color,
                  borderRadius: 10,
                  width: 48,
                  height: 48,
                  placeholder: Center(
                    child: Icon(
                      pl.builtIn
                          ? LucideIcons.heart
                          : LucideIcons.listMusic,
                      color: Colors.white.withValues(alpha: 0.6),
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pl.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        l10n.songsCount(pl.count),
                        style: WlText.mono(
                          fontSize: 11,
                          color: AppTheme.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  LucideIcons.chevronRight,
                  color: AppTheme.textTertiary,
                  size: 18,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showCreatePlaylist(BuildContext context, PlaybackProvider player) {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          l10n.newPlaylist,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: l10n.playlistNameHint,
            hintStyle: TextStyle(color: AppTheme.textTertiary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.textTertiary),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.brand),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              l10n.cancel,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                await player.saveCurrentQueueAsPlaylist(name);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(
              l10n.save,
              style: const TextStyle(color: AppTheme.brand),
            ),
          ),
        ],
      ),
    );
  }

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Coming soon'),
        backgroundColor: AppTheme.s3,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _PlaylistEntry {
  final String name;
  final int count;
  final Color color;
  final List<Song> songs;
  final bool builtIn;
  const _PlaylistEntry({
    required this.name,
    required this.count,
    required this.color,
    required this.songs,
    this.builtIn = false,
  });
}

// ── Context Menu ──

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
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                WlCover(
                  coverUrl: song.coverUrl,
                  fallbackColor: song.dominantColor,
                  borderRadius: 8,
                  width: 48,
                  height: 48,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${song.artist} · ${song.album}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _MenuItem(
            icon: LucideIcons.skipForward,
            label: l10n.playNext,
            onTap: () {
              player.playNext(song);
              Navigator.pop(ctx);
            },
          ),
          _MenuItem(
            icon: LucideIcons.listMusic,
            label: l10n.addToQueue,
            onTap: () {
              player.addToQueue(song);
              Navigator.pop(ctx);
            },
          ),
          _MenuItem(
            icon: LucideIcons.listPlus,
            label: l10n.addToPlaylist,
            onTap: () => _showAddToPlaylist(ctx, song, player),
          ),
          _MenuItem(
            icon: player.isSongFavorite(song.id)
                ? LucideIcons.heart
                : LucideIcons.heart,
            label: player.isSongFavorite(song.id)
                ? l10n.unfavorite
                : l10n.favorite,
            onTap: () {
              player.setFavorite(song.id, !player.isSongFavorite(song.id));
              Navigator.pop(ctx);
            },
          ),
          const Divider(height: 1),
          _MenuItem(
            icon: LucideIcons.trash2,
            label: l10n.deleteFromLibrary,
            isDestructive: true,
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: isDestructive ? AppTheme.danger : AppTheme.textPrimary,
        size: 22,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: isDestructive ? AppTheme.danger : AppTheme.textPrimary,
        ),
      ),
      onTap: onTap,
      dense: true,
    );
  }
}

void _showAddToPlaylist(
  BuildContext context,
  Song song,
  PlaybackProvider player,
) {
  final l10n = AppLocalizations.of(context);
  final saved = player.playlists;
  Navigator.pop(context);
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              l10n.addToPlaylist,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          const Divider(height: 1),
          if (saved.isEmpty)
            ListTile(
              leading: const Icon(
                LucideIcons.info,
                color: AppTheme.textTertiary,
              ),
              title: Text(
                l10n.noPlaylists,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ...saved.entries.map(
            (e) => ListTile(
              leading: const Icon(
                LucideIcons.listMusic,
                color: AppTheme.brand,
              ),
              title: Text(
                e.key,
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () async {
                final ids = [...e.value, song.id];
                await player.savePlaylist(e.key, ids);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
          ),
        ],
      ),
    ),
  );
}
