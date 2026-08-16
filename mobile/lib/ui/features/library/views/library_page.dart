import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../data/services/log.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../domain/models/song.dart';
import '../../../../data/services/preferences_service.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../../../core/widgets/wl_toggle.dart';
import '../../playback/view_models/playback_controller.dart';
import '../../playback/view_models/audio_player_provider.dart';
import '../../playback/view_models/queue_provider.dart';
import '../view_models/library_provider.dart';
import '../../../core/animations/app_animations.dart';
import '../view_models/library_header_notifier.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/song_tile.dart';
import '../../../core/widgets/album_cover.dart';

/// 曲库标签栏右侧「音源过滤」按钮：点击从底部弹出过滤 sheet，
/// 复用抽屉里同一套来源开关策略（PreferencesService.showSource + refreshSources）。
class _SourceFilterButton extends StatelessWidget {
  final VoidCallback onOpen;
  const _SourceFilterButton({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Tooltip(
      message: l10n.sourcesSection,
      child: SizedBox(
        width: 36,
        height: 38,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onOpen,
          child: Align(
            alignment: Alignment.centerRight,
            child: Icon(
              LucideIcons.filter,
              size: 18,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 音源过滤底部 sheet：列出全部音源的开关，勾选即过滤曲库。
/// 逻辑与抽屉 _SourceRow 的开关完全一致（仅做过滤，不触发扫描）。
class _SourceFilterSheet extends StatefulWidget {
  final Future<void> Function(SongSource, bool) onChanged;
  const _SourceFilterSheet({required this.onChanged});

  @override
  State<_SourceFilterSheet> createState() => _SourceFilterSheetState();
}

class _SourceFilterSheetState extends State<_SourceFilterSheet> {
  final PreferencesService _prefs = PreferencesService.instance;

  Future<void> _toggle(SongSource source, bool value) async {
    await widget.onChanged(source, value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isIos = Platform.isIOS;
    final localSource = isIos ? SongSource.appleMusic : SongSource.local;
    final localValue = isIos ? _prefs.showAppleMusic : _prefs.showLocal;
    final rows = <Widget>[
      _FilterRow(
        icon: isIos ? LucideIcons.apple : LucideIcons.smartphone,
        label: isIos ? l10n.sourceAppleMusic : l10n.sourceDeviceLibrary,
        value: localValue,
        onChanged: () => _toggle(localSource, !localValue),
      ),
      _FilterRow(
        icon: LucideIcons.folderOpen,
        label: l10n.sourceFileImport,
        value: _prefs.showImported,
        onChanged: () => _toggle(SongSource.imported, !_prefs.showImported),
      ),
      _FilterRow(
        icon: LucideIcons.hardDrive,
        label: l10n.sourceNas,
        value: _prefs.showNas,
        onChanged: () => _toggle(SongSource.nas, !_prefs.showNas),
      ),
      _FilterRow(
        icon: LucideIcons.cloud,
        label: l10n.sourceWebdav,
        value: _prefs.showWebdav,
        onChanged: () => _toggle(SongSource.webdav, !_prefs.showWebdav),
      ),
      _FilterRow(
        icon: LucideIcons.server,
        label: l10n.sourceMusicServer,
        value: _prefs.showSubsonic,
        onChanged: () => _toggle(SongSource.subsonic, !_prefs.showSubsonic),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.sourcesSection,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          ...rows,
        ],
      ),
    );
  }
}

/// 过滤 sheet 的单项：图标 + 名称 + 右侧 WlToggle 开关
class _FilterRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final VoidCallback onChanged;
  const _FilterRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 整行可点：行内任意位置（含文字）切换开关
      onTap: onChanged,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            WlToggle(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // 搜索状态与键盘焦点解耦：键盘收起（点完成/点外部）只收键盘、不关搜索；
    // 关闭只走显式入口（顶部搜索图标 / 清空 X / 再点输入框外不关闭）。
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // 来源按钮 → 弹出音源过滤底部 sheet（复用抽屉开关策略）
  void _openSourceSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SourceFilterSheet(
        onChanged: (SongSource source, bool value) async {
          final prefs = PreferencesService.instance;
          switch (source) {
            case SongSource.nas:
              await prefs.setShowNas(value);
            case SongSource.webdav:
              await prefs.setShowWebdav(value);
            case SongSource.appleMusic:
              await prefs.setShowAppleMusic(value);
            case SongSource.subsonic:
              await prefs.setShowSubsonic(value);
            case SongSource.imported:
              await prefs.setShowImported(value);
            case SongSource.local:
              await prefs.setShowLocal(value);
          }
          if (mounted) ref.read(libraryProvider.notifier).refreshSources();
        },
      ),
    );
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
        Fluttertoast.showToast(
          msg: next,
          gravity: ToastGravity.BOTTOM,
          timeInSecForIosWeb: 2,
          fontSize: 13,
          backgroundColor: AppTheme.danger,
          textColor: AppTheme.textPrimary,
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
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppTheme.s2,
                borderRadius: BorderRadius.circular(8),
              ),
              // Row 布局替代 InputDecoration.prefixIcon：prefixIcon 插槽默认
              // 最小高度约束(≈48px)超出 40px 容器会把文字/光标挤偏。Row 默认
              // crossAxisAlignment.center 保证图标垂直居中，TextField 用
              // isDense + textAlignVertical.center 让 hint/光标与文字同中线。
              child: Row(
                children: [
                  const Icon(
                    LucideIcons.search,
                    size: 16,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      // 键盘"完成/搜索"只收键盘，搜索与结果保留
                      onSubmitted: (_) => _searchFocusNode.unfocus(),
                      onChanged: (v) =>
                          headerNotifier.setQuery(v.toLowerCase()),
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textPrimary,
                        fontFamily: 'Inter',
                      ),
                      textAlignVertical: TextAlignVertical.center,
                      decoration: InputDecoration(
                        hintText: l10n.searchLibrary,
                        hintStyle: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textTertiary,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  // 清空按钮：有输入时显示，点击清空关键词并回到输入态（不退出搜索）
                  if (headerState.searchQuery.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _searchController.clear();
                        headerNotifier.setQuery('');
                        _searchFocusNode.requestFocus();
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          LucideIcons.x,
                          size: 16,
                          color: AppTheme.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

        // ── 紧凑标签栏：与内容列对齐（水平 16）、不平分、下划线指示器 ──
        // 最右侧「来源」图标按钮：弹出音源菜单，复用 PlaybackController / 路由
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: EdgeInsets.zero,
                  indicatorSize: TabBarIndicatorSize.label,
                  indicator: const UnderlineTabIndicator(
                    borderSide: BorderSide(
                      width: 2,
                      color: AppTheme.textPrimary,
                    ),
                    insets: EdgeInsets.symmetric(horizontal: 0),
                  ),
                  dividerColor: Colors.transparent,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  labelColor: AppTheme.textPrimary,
                  unselectedLabelColor: AppTheme.textTertiary,
                  labelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                  tabs: [
                    Tab(height: 38, text: l10n.libSongs),
                    Tab(height: 38, text: l10n.libAlbums),
                    Tab(height: 38, text: l10n.libArtists),
                    Tab(height: 38, text: l10n.libPlaylists),
                  ],
                ),
              ),
              // ── 来源图标按钮 ──
              _SourceFilterButton(onOpen: _openSourceSheet),
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

    final query = headerState.searchQuery;
    final displayed = query.isEmpty
        ? allSongs
        : allSongs
              .where(
                (s) =>
                    s.title.toLowerCase().contains(query) ||
                    s.artist.toLowerCase().contains(query) ||
                    s.album.toLowerCase().contains(query),
              )
              .toList();

    if (displayed.isEmpty) {
      return _EmptyLibrary(
        message: query.isNotEmpty ? l10n.noResults : l10n.noMusicHint,
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
            onTap: () {
              Log.d('Audio', '[pt] 用户点击 ${song.title}');
              // 流媒体风格点歌：当前曲不重播（播放中→播放页，暂停→恢复）
              if (!player.tapSong(displayed, index, song)) return;
              if (isPlaying) {
                context.push('/now-playing');
              } else {
                player.togglePlay();
              }
            },
            onMore: () => _showContextMenu(context, song, player),
            // 收藏爱心仅作展示（收藏动作走三点菜单）
            trailing: player.isSongFavorite(song.id)
                ? const Icon(Icons.favorite, size: 16, color: AppTheme.danger)
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
    final query = ref.watch(libraryHeaderProvider).searchQuery;

    // 按专辑分组：单次 O(N) 遍历（保留首次出现顺序），
    // 避免原来每次 build 的 map/toSet + itemBuilder 内逐专辑 where 扫描。
    // 键用「艺人+专辑名」复合：仅按专辑名会把不同艺人的同名专辑
    //（精选集/金曲等常见名）合并成一张，歌曲混排、艺人信息丢失。
    final albums = <String, List<Song>>{};
    for (final s in songs) {
      (albums['${s.artist}\u0000${s.album}'] ??= []).add(s);
    }
    // 搜索：专辑/艺人名命中才显示（键 = 艺人\0专辑名，contains 即覆盖两者）
    final albumNames = albums.keys
        .where((k) => query.isEmpty || k.toLowerCase().contains(query))
        .toList();
    if (albumNames.isEmpty) {
      return _EmptyLibrary(
        message: query.isNotEmpty ? l10n.noResults : l10n.noAlbumInfo,
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 80, left: 16, right: 16, top: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.72,
      ),
      itemCount: albumNames.length,
      itemBuilder: (context, index) {
        final albumSongs = albums[albumNames[index]]!;
        // 展示/判定一律以首曲元数据为准（同组内艺人+专辑名一致）
        final name = albumSongs.first.album;
        final artist = albumSongs.first.artist;
        final color = albumSongs.first.dominantColor;
        final isPlayingAlbum =
            queueState.currentSong?.album == name &&
            queueState.currentSong?.artist == artist &&
            isPlaying;

        return AppAnim.listEntrance(
          GestureDetector(
            behavior: HitTestBehavior.opaque, // 行内空白也可点
            onTap: () => context.push(
              '/album',
              extra: Album(
                id: '$artist\u0000$name',
                title: name,
                artist: artist,
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
    final query = ref.watch(libraryHeaderProvider).searchQuery;

    // 按艺人分组：单次 O(N) 遍历，避免 itemBuilder 内逐艺人 where 扫描
    final artists = <String, List<Song>>{};
    for (final s in songs) {
      (artists[s.artist] ??= []).add(s);
    }
    // 搜索：艺人名命中才显示
    final artistNames = artists.keys
        .where((n) => query.isEmpty || n.toLowerCase().contains(query))
        .toList();
    if (artistNames.isEmpty) {
      return _EmptyLibrary(
        message: query.isNotEmpty ? l10n.noResults : l10n.noArtistInfo,
      );
    }

    return CustomScrollView(
      slivers: [
        // 全部随机播放按钮（搜索时隐藏：它随机的是全库而非搜索结果）
        if (query.isEmpty)
          SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (songs.isNotEmpty) {
                      player.setLoopMode(LoopMode.shuffle);
                      player.playAlbum(songs, startIndex: 0);
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
          delegate: SliverChildBuilderDelegate((context, index) {
            final name = artistNames[index];
            final artistSongs = artists[name]!;
            final count = artistSongs.length;
            final albumCount = artistSongs.map((s) => s.album).toSet().length;
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
          }, childCount: artistNames.length),
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
    final query = ref.watch(libraryHeaderProvider).searchQuery;

    // "我喜欢的音乐" 固定在最前，其余为已保存播放列表；
    // 搜索时按播放列表名过滤（与歌曲/专辑/艺术家 tab 一致，搜索贯穿全库）
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
    ]
        .where((e) => query.isEmpty || e.name.toLowerCase().contains(query))
        .toList();

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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
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
                            pl.builtIn ? Icons.favorite : LucideIcons.listMusic,
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
                      // 非内置播放列表提供删除入口
                      if (!pl.builtIn) ...[
                        IconButton(
                          icon: const Icon(
                            LucideIcons.moreVertical,
                            color: AppTheme.textTertiary,
                            size: 18,
                          ),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _confirmDeletePlaylist(
                            context,
                            pl.name,
                            player,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
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
    // 苹果式底部半模态：拖拽把手 + 居中标题 + 右上角完成 +
    // 分组卡片内联输入（替代居中 AlertDialog）；键盘弹出时内容上移避让
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        // 键盘避让：输入框聚焦弹出键盘时 sheet 整体上移
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: AppTheme.surfaceDark,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 拖拽把手（与 SheetShell 一致）
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.textTertiary.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                // 标题行：居中标题 + 右上角完成（iOS 导航风格）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        l10n.newPlaylist,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Positioned(
                        right: 0,
                        child: TextButton(
                          onPressed: () async {
                            final name = ctrl.text.trim();
                            if (name.isEmpty) return;
                            final ok = await player.createEmptyPlaylist(name);
                            if (!ok) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(content: Text(l10n.playlistNameExists)),
                                  );
                              }
                              return;
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          child: Text(
                            l10n.save,
                            style: TextStyle(
                              color: AccentScope.of(context),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 分组卡片内联输入行（inset-group 风格）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        Icon(
                          LucideIcons.music2,
                          size: 18,
                          color: AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: ctrl,
                            autofocus: true,
                            style: const TextStyle(
                              fontSize: 15,
                              color: AppTheme.textPrimary,
                            ),
                            decoration: InputDecoration(
                              hintText: l10n.playlistNameHint,
                              hintStyle: TextStyle(
                                color: AppTheme.textTertiary,
                              ),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 14,
                              ),
                            ),
                            onSubmitted: (_) async {
                              final name = ctrl.text.trim();
                              if (name.isEmpty) return;
                              final ok = await player.createEmptyPlaylist(name);
                              if (!ok) {
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx)
                                    ..hideCurrentSnackBar()
                                    ..showSnackBar(
                                      SnackBar(content: Text(l10n.playlistNameExists)),
                                    );
                                }
                                return;
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 次级说明（新建的是空列表）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Text(
                    l10n.createPlaylistHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).then((_) => ctrl.dispose());
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

/// 删除播放列表确认对话框：确认后移除该播放列表（歌曲本身不受影响）。
Future<void> _confirmDeletePlaylist(
  BuildContext context,
  String name,
  PlaybackController player,
) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surfaceDark,
      title: Text(l10n.deleteConfirmTitle),
      content: Text(l10n.deletePlaylistBody(name)),
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
    await player.deletePlaylist(name);
  }
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
    builder: (ctx) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Container(
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
                icon: LucideIcons.listPlus,
                label: l10n.addToPlaylist,
                onTap: () => _showAddToPlaylist(ctx, song, player),
              ),
              _MenuItem(
                icon: player.isSongFavorite(song.id)
                    ? Icons.favorite
                    : Icons.favorite_border,
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
              leading: const Icon(LucideIcons.listMusic, color: AppTheme.brand),
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
