import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../domain/models/song.dart';
import '../../../../data/services/rust_service.dart' as rs;
import '../../../../data/services/file_picker_service.dart';
import '../../playback/view_models/playback_controller.dart';
import '../../playback/view_models/audio_player_provider.dart';
import '../../playback/view_models/queue_provider.dart';
import '../view_models/library_provider.dart';
import '../../../core/animations/app_animations.dart';
import '../view_models/library_header_notifier.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../core/widgets/album_cover.dart';


class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
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
    final headerState = ref.watch(libraryHeaderProvider);
    final headerNotifier = ref.read(libraryHeaderProvider.notifier);

    // 播放失败提示（文件不存在/下载失败）：弹一次即清，
    // 避免静默回滚让用户困惑为什么没播。
    ref.listen(playErrorProvider, (prev, next) {
      if (next != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
        ref.read(playErrorProvider.notifier).clear();
      }
    });

    return Column(
      children: [
        // ── Search bar (toggled from AppShell top-right icon) ──
        if (headerState.isSearchVisible)
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
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 12),
              tabs: [
                Tab(text: l10n.libSongs,height: 44,),
                Tab(text: l10n.libAlbums,height: 44,),
                Tab(text: l10n.libArtists,height: 44,),
                Tab(text: l10n.libPlaylists,height: 44,),
              ],
              onTap: (_) {
                // 切 tab 时关闭搜索
                if (ref.read(libraryHeaderProvider).isSearchVisible) {
                  ref.read(libraryHeaderProvider.notifier).closeSearch();
                  _searchController.clear();
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),

        // ── NAS 后台导入进度条 ──
        if (ref.watch(libraryProvider).nasImporting ||
            ref.watch(libraryProvider).nasImportError != null)
          const _NasImportBanner(),

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

// ── NAS 后台导入进度条 ──

class _NasImportBanner extends ConsumerWidget {
  const _NasImportBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final lib = ref.watch(libraryProvider);
    final accent = AccentScope.of(context);
    final error = lib.nasImportError;

    if (error != null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(
              LucideIcons.alertTriangle,
              size: 16,
              color: AppTheme.danger,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.danger,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.s2,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.nasImportingProgress(lib.nasImportedCount),
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          GestureDetector(
            onTap: () =>
                ref.read(libraryProvider.notifier).cancelNasImport(),
            child: const Icon(
              LucideIcons.x,
              size: 16,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
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

class _SongsTab extends ConsumerWidget {
  const _SongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    // 只 select isPlaying：列表页不需要 position，避免 250ms tick 重建全列表
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final queueState = ref.watch(queueProvider);
    final libraryState = ref.watch(libraryProvider);
    final headerState = ref.watch(libraryHeaderProvider);
    final allSongs = libraryState.allSongs;

    // 曲目 id → 全库序号（itemBuilder 内 O(1)，避免 indexOf 每行 O(N)）
    final trackNumbers = <String, int>{
      for (var i = 0; i < allSongs.length; i++) allSongs[i].id: i + 1,
    };

    final query = headerState.searchQuery;
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
        final isCurrent = queueState.currentSong?.id == song.id;
        return AppAnim.listEntrance(
          SongTile(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isPlaying && isCurrent,
            trackNumber: trackNumbers[song.id] ?? index + 1,
            onTap: () => player.playSong(song),
            onMore: () => _showContextMenu(context, song, player),
            trailing: player.isSongFavorite(song.id)
                ? const Icon(
                    LucideIcons.heart,
                    size: 16,
                    color: AppTheme.danger,
                  )
                : null,
          ),
          index,
        );
      },
    );
  }
}

// ── Albums Tab ──

class _AlbumsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // 只 select isPlaying：避免 250ms tick 重建专辑网格
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final queueState = ref.watch(queueProvider);
    final songs = ref.watch(libraryProvider).allSongs;

    // 按专辑分组：单次 O(N) 遍历（保留首次出现顺序），
    // 避免原来每次 build 的 map/toSet + itemBuilder 内逐专辑 where 扫描
    final albums = <String, List<Song>>{};
    for (final s in songs) {
      (albums[s.album] ??= []).add(s);
    }
    final albumNames = albums.keys.toList();
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
        final albumSongs = albums[name]!;
        final color = albumSongs.first.dominantColor;
        final isPlayingAlbum =
            queueState.currentSong?.album == name && isPlaying;

        return AppAnim.listEntrance(
        GestureDetector(
          behavior: HitTestBehavior.opaque, // 行内空白也可点
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
              // 专辑封面
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
              // 专辑标题
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
              // 单行元信息
              Text(
                '${albumSongs.length} songs',
                style: WlText.mono(
                  fontSize: 11,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
        ),
          index,
        );
      },
    );
  }
}

// ── Artists Tab ──

class _ArtistsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    final songs = ref.watch(libraryProvider).allSongs;

    // 按艺人分组：单次 O(N) 遍历，避免 itemBuilder 内逐艺人 where 扫描
    final artists = <String, List<Song>>{};
    for (final s in songs) {
      (artists[s.artist] ??= []).add(s);
    }
    final artistNames = artists.keys.toList();
    if (artistNames.isEmpty) {
      return _EmptyLibrary(message: l10n.noArtistInfo);
    }

    return CustomScrollView(
      slivers: [
        // 全部随机播放按钮
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
        // 艺术家列表
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final name = artistNames[index];
              final artistSongs = artists[name]!;
              final count = artistSongs.length;
              final albumCount =
                  artistSongs.map((s) => s.album).toSet().length;
              final artistColor = artistSongs.first.dominantColor;

              return AppAnim.listEntrance(
              GestureDetector(
                behavior: HitTestBehavior.opaque, // 行内空白也可点
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
              ),
                index,
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

class _PlaylistsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    ref.watch(libraryProvider); // 收藏/播放列表变化时刷新
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
          return AppAnim.listEntrance(
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                // 新建播放列表
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
                // 导入/导出
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openPlaylistIo(context, player),
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
          ),
            index,
          );
        }

        final pl = entries[index - 1];
        // margin 放外层 Padding（项间空隙不误触）；InkWell 默认 opaque 命中整个
        // 行区域（含文字/封面之外的空白），并带水波纹反馈——裸 GestureDetector
        // 只响应实际渲染元素，点行内空白会"无响应"。
        return AppAnim.listEntrance(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => context.push(
                '/song-list',
                extra: {
                  'title': pl.name,
                  'songs': pl.songs,
                  'accentColor': pl.color,
                  'isFavoriteList': pl.builtIn,
                },
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    WlCover(
                      coverUrl: pl.songs.isNotEmpty
                          ? pl.songs.first.coverUrl
                          : null,
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
            ),
          ),
        ),
          index,
        );
      },
    );
  }

  void _showCreatePlaylist(BuildContext context, PlaybackController player) {
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

  void _openPlaylistIo(BuildContext context, PlaybackController player) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.s2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                LucideIcons.upload,
                color: AppTheme.textSecondary,
              ),
              title: const Text(
                '导入播放列表（M3U / PLS）',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _importPlaylist(context, player);
              },
            ),
            ListTile(
              leading: const Icon(
                LucideIcons.download,
                color: AppTheme.textSecondary,
              ),
              title: const Text(
                '导出当前队列为 M3U',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _exportPlaylist(context, player);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 导入：选文件 → Rust 解析 M3U/PLS → 转为 Song 队列并播放。
  Future<void> _importPlaylist(
    BuildContext context,
    PlaybackController player,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final paths = await FilePickerService.pickFiles(
      extensions: const ['m3u', 'm3u8', 'pls'],
      multiple: false,
    );
    if (paths.isEmpty) {
      _toast(messenger, '未选择播放列表文件');
      return;
    }
    if (!rs.rustAvailable) {
      _toast(messenger, 'Rust 引擎不可用，无法解析');
      return;
    }
    try {
      final entries = await rs.parsePlaylistFile(paths.first);
      if (entries.isEmpty) {
        _toast(messenger, '播放列表为空');
        return;
      }
      final songs = entries.map((e) {
        final isStream = e.path.startsWith('http://') ||
            e.path.startsWith('https://');
        final name = (e.title == null || e.title!.isEmpty)
            ? e.path.split(RegExp(r'[/\\]')).last
            : e.title!;
        return Song(
          id: e.path,
          title: name,
          artist: '',
          album: '',
          duration: Duration(seconds: e.durationSecs.round()),
          dominantColor: AppTheme.brand,
          path: isStream ? null : e.path,
          streamUrl: isStream ? e.path : null,
        );
      }).toList();
      player.playAlbum(songs);
      _toast(messenger, '已导入并播放 ${songs.length} 首');
    } catch (e) {
      _toast(messenger, '解析失败: $e');
    }
  }

  /// 导出：把当前队列写成 M3U 到 Documents/Playlists/。
  /// 注：未接入系统分享/另存面板，文件落在应用 Documents 目录（iOS 经 Files 应用可取回）。
  Future<void> _exportPlaylist(
    BuildContext context,
    PlaybackController player,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final queue = player.queue;
    if (queue.isEmpty) {
      _toast(messenger, '当前队列为空，无可导出');
      return;
    }
    try {
      final buffer = StringBuffer('#EXTM3U\n');
      for (final s in queue) {
        final artist = s.artist.isEmpty ? '' : '${s.artist} - ';
        buffer.writeln(
            '#EXTINF:${s.durationEstimated ? 0 : s.duration.inSeconds},$artist${s.title}');
        buffer.writeln(s.path ?? s.streamUrl ?? '');
      }
      final docs = await getApplicationDocumentsDirectory();
      final outDir = Directory('${docs.path}/Playlists');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final file = File('${outDir.path}/queue_$stamp.m3u');
      await file.writeAsString(buffer.toString());
      _toast(messenger, '已导出 ${queue.length} 首：${file.path}');
    } catch (e) {
      _toast(messenger, '导出失败: $e');
    }
  }

  void _toast(ScaffoldMessengerState messenger, String msg) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
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
  PlaybackController player,
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
                        song.artistAlbumLine,
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
            onTap: () {
              Navigator.pop(ctx);
              _confirmDelete(context, song, player);
            },
          ),
        ],
      ),
    ),
  );
}

/// 删除确认对话框：确认后从曲库/收藏/队列移除，
/// 并清理沙盒内物理文件（导入副本/下载缓存/封面）。
Future<void> _confirmDelete(
  BuildContext context,
  Song song,
  PlaybackController player,
) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surfaceDark,
      title: Text(l10n.deleteConfirmTitle),
      content: Text(l10n.deleteConfirmBody(song.title)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            l10n.delete,
            style: const TextStyle(color: AppTheme.danger),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await player.removeSong(song);
  }
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
  PlaybackController player,
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
