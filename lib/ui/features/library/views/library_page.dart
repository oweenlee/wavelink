import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../domain/models/song.dart';
import '../../playback/view_models/playback_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/song_tile.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: AppTheme.brand,
            unselectedLabelColor: AppTheme.textTertiary,
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            unselectedLabelStyle: const TextStyle(fontSize: 13),
            tabs: [
              Tab(text: l10n.libSongs),
              Tab(text: l10n.libAlbums),
              Tab(text: l10n.libArtists),
              Tab(text: l10n.libPlaylists),
            ],
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
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final songs = player.allSongs;

    return Column(
      children: [
        _ImportHeader(importCount: songs.length),
        Expanded(
          child: songs.isEmpty
              ? _EmptyLibrary(message: l10n.noMusicHint)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    final isPlaying =
                        player.isPlaying && player.currentSong?.id == song.id;
                    return SongTile(
                      song: song,
                      isPlaying: isPlaying,
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
                ),
        ),
      ],
    );
  }
}

class _ImportHeader extends StatelessWidget {
  final int importCount;
  const _ImportHeader({required this.importCount});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Icon(
            LucideIcons.folderOpen,
            size: 18,
            color: AppTheme.brand,
          ),
          const SizedBox(width: 8),
          Text(
            importCount > 0 ? l10n.importN(importCount) : l10n.importMusic,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => context.push('/import'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.plus, size: 16, color: AppTheme.brand),
                  SizedBox(width: 4),
                  Text(
                    l10n.import,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.brand,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80, left: 16, right: 16, top: 8),
      itemCount: albumNames.length,
      itemBuilder: (context, index) {
        final name = albumNames[index];
        final albumSongs = songs.where((s) => s.album == name).toList();
        final color = albumSongs.first.dominantColor;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: GestureDetector(
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
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Icon(
                      LucideIcons.album,
                      color: Colors.white.withValues(alpha: 0.5),
                      size: 28,
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
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.albumArtistCount(
                          albumSongs.first.artist,
                          albumSongs.length,
                        ),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  LucideIcons.chevronRight,
                  color: AppTheme.textTertiary,
                  size: 20,
                ),
              ],
            ),
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

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80, left: 16, right: 16, top: 8),
      itemCount: artistNames.length,
      itemBuilder: (context, index) {
        final name = artistNames[index];
        final count = songs.where((s) => s.artist == name).length;
        final artistColor = songs
            .firstWhere((s) => s.artist == name)
            .dominantColor;

        return GestureDetector(
          onTap: () => context.push(
            '/artist',
            extra: {'name': name, 'color': artistColor},
          ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: artistColor,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Center(
                    child: Text(
                      name.isNotEmpty ? name[0] : '?',
                      style: const TextStyle(
                        fontSize: 20,
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
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.songsCount(count),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  LucideIcons.chevronRight,
                  color: AppTheme.textTertiary,
                  size: 20,
                ),
              ],
            ),
          ),
        );
      },
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
            child: GestureDetector(
              onTap: () => _showCreatePlaylist(context, player),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.brand.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.plus, color: AppTheme.brand, size: 20),
                    SizedBox(width: 8),
                    Text(
                      l10n.newPlaylistFromQueue,
                      style: TextStyle(
                        fontSize: 15,
                        color: AppTheme.brand,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
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
            margin: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: pl.color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Icon(
                      pl.builtIn
                          ? LucideIcons.heart
                          : LucideIcons.listMusic,
                      color: Colors.white.withValues(alpha: 0.6),
                      size: 24,
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
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.songsCount(pl.count),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  LucideIcons.chevronRight,
                  color: AppTheme.textTertiary,
                  size: 20,
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
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: song.dominantColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
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
