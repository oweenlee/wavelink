import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_anim.dart';
import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../services/media_index.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';
import '../widgets/detail_header.dart';
import '../widgets/media_card.dart';
import '../widgets/search_field.dart';
import '../widgets/track_row.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;

// ═══════════════════════════════════════════════════════════════════════════
// 艺术家 / 专辑 媒体库视图（派生自 player.library，纯展示，不触碰引擎 / core）
// ═══════════════════════════════════════════════════════════════════════════

/// 列表 / 详情页共用的顶部工具条：搜索框 + 排序 + 标题 + 计数。
class _ViewHeader extends StatelessWidget {
  final String title;
  final String countLabel;
  final TextEditingController queryCtrl;
  final ValueChanged<String> onQuery;
  final int sort;
  final ValueChanged<int> onSort;
  final String sortLabel1;
  final String sortLabel2;
  const _ViewHeader({
    required this.title,
    required this.countLabel,
    required this.queryCtrl,
    required this.onQuery,
    required this.sort,
    required this.onSort,
    required this.sortLabel1,
    required this.sortLabel2,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SearchField(controller: queryCtrl, onChanged: onQuery),
              ),
              const SizedBox(width: 10),
              SortMenu(
                sort: sort,
                onSort: onSort,
                labels: [l10n.sortDefault, sortLabel1, sortLabel2],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(title,
                  style: const TextStyle(
                      color: _onSurface, fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text(countLabel,
                  style: const TextStyle(color: _onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 艺术家索引视图：响应式网格 + 搜索 + 排序 + 无限滚动懒加载。
class ArtistsView extends ConsumerStatefulWidget {
  final PlayerController player;
  final ValueChanged<String> onOpenArtist;
  const ArtistsView({super.key, required this.player, required this.onOpenArtist});

  @override
  ConsumerState<ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends ConsumerState<ArtistsView> {
  final _queryCtrl = TextEditingController();
  final _scroll = ScrollController();
  static const _pageSize = 60;
  String _query = '';
  int _sort = 0;
  int _loaded = _pageSize;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240 &&
        _loaded < _total) {
      setState(() => _loaded = (_loaded + _pageSize).clamp(0, _total));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    final l10n = AppLocalizations.of(context);
    final idx = MediaIndex.build(widget.player.library);
    var list = MediaIndex.filterArtists(idx.artists, _query);
    list = MediaIndex.sortArtists(list, _sort);
    _total = list.length;
    if (_loaded > _total) _loaded = _total;
    final shown = list.take(_loaded).toList();
    return Column(
      children: [
        _ViewHeader(
          title: l10n.viewArtists,
          countLabel: l10n.artistCount(list.length),
          queryCtrl: _queryCtrl,
          onQuery: (v) => setState(() {
            _query = v;
            _loaded = _pageSize;
          }),
          sort: _sort,
          onSort: (v) => setState(() => _sort = v),
          sortLabel1: l10n.sortByName,
          sortLabel2: l10n.sortByCount,
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    _query.isEmpty ? l10n.noArtists : l10n.noMatch,
                    style: const TextStyle(color: _onSurfaceVariant),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final (cols, cellW) = gridMetrics(constraints.maxWidth, hPad: 40);
                    return GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: cellW / (cellW + 52),
                      ),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final a = shown[i];
                        final name =
                            a.name.isEmpty ? l10n.artistUnknown : a.name;
                        return MediaCard(
                          seed: a.name.isEmpty ? 'unknown-artist' : a.name,
                          coverUrl: a.coverUrl,
                          coverSize: cellW,
                          title: name,
                          subtitle: l10n.albumCount(a.albums.length),
                          onTap: () =>
                              widget.onOpenArtist(a.name.isEmpty ? '' : a.name),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 专辑索引视图：与艺术家视图对称。
class AlbumsView extends ConsumerStatefulWidget {
  final PlayerController player;
  final ValueChanged<String> onOpenAlbum;
  const AlbumsView({super.key, required this.player, required this.onOpenAlbum});

  @override
  ConsumerState<AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends ConsumerState<AlbumsView> {
  final _queryCtrl = TextEditingController();
  final _scroll = ScrollController();
  static const _pageSize = 60;
  String _query = '';
  int _sort = 0;
  int _loaded = _pageSize;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240 &&
        _loaded < _total) {
      setState(() => _loaded = (_loaded + _pageSize).clamp(0, _total));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryProvider);
    final l10n = AppLocalizations.of(context);
    final idx = MediaIndex.build(widget.player.library);
    var list = MediaIndex.filterAlbums(idx.albums, _query);
    list = MediaIndex.sortAlbums(list, _sort);
    _total = list.length;
    if (_loaded > _total) _loaded = _total;
    final shown = list.take(_loaded).toList();
    return Column(
      children: [
        _ViewHeader(
          title: l10n.viewAlbums,
          countLabel: l10n.albumCount(list.length),
          queryCtrl: _queryCtrl,
          onQuery: (v) => setState(() {
            _query = v;
            _loaded = _pageSize;
          }),
          sort: _sort,
          onSort: (v) => setState(() => _sort = v),
          sortLabel1: l10n.sortByName,
          sortLabel2: l10n.sortByCount,
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    _query.isEmpty ? l10n.noAlbums : l10n.noMatch,
                    style: const TextStyle(color: _onSurfaceVariant),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final (cols, cellW) = gridMetrics(constraints.maxWidth, hPad: 40);
                    return GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: cellW / (cellW + 52),
                      ),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final al = shown[i];
                        final name =
                            al.name.isEmpty ? l10n.albumUnknown : al.name;
                        return MediaCard(
                          seed: al.key,
                          coverUrl: al.coverUrl,
                          coverSize: cellW,
                          title: name,
                          subtitle: al.artist.isEmpty
                              ? l10n.artistUnknown
                              : al.artist,
                          onTap: () => widget.onOpenAlbum(al.key),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 专辑网格（用于艺术家详情页内的作品集）。
class _AlbumGrid extends StatelessWidget {
  final List<AlbumGroup> albums;
  final AppLocalizations l10n;
  final ValueChanged<String> onOpenAlbum;
  const _AlbumGrid({
    required this.albums,
    required this.l10n,
    required this.onOpenAlbum,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final (cols, cellW) = gridMetrics(constraints.maxWidth);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: cellW / (cellW + 52),
          ),
          itemCount: albums.length,
          itemBuilder: (_, i) {
            final al = albums[i];
            final name = al.name.isEmpty ? l10n.albumUnknown : al.name;
            return MediaCard(
              seed: al.key,
              coverUrl: al.coverUrl,
              coverSize: cellW,
              title: name,
              subtitle: al.artist.isEmpty ? l10n.artistUnknown : al.artist,
              onTap: () => onOpenAlbum(al.key),
            );
          },
        );
      },
    );
  }
}

/// 艺术家详情：头部 + 专辑网格 + 全部曲目列表。
class ArtistDetail extends ConsumerWidget {
  final PlayerController player;
  final String artistKey;
  final ValueChanged<String> onOpenAlbum;
  final VoidCallback onBack;
  const ArtistDetail({
    super.key,
    required this.player,
    required this.artistKey,
    required this.onOpenAlbum,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryProvider);
    ref.watch(currentIndexProvider);
    final playing = ref.watch(playingProvider).value ?? false;
    final l10n = AppLocalizations.of(context);
    final idx = MediaIndex.build(player.library);
    final artist = idx.artistByName(artistKey);
    if (artist == null) return detailEmpty(l10n);
    final name = artist.name.isEmpty ? l10n.artistUnknown : artist.name;
    final currentId = player.currentTrack?.id;
    return Column(
      children: [
        DetailHeader(
          coverUrl: artist.coverUrl,
          seed: artist.name.isEmpty ? 'unknown-artist' : artist.name,
          title: name,
          subtitle:
              '${l10n.albumCount(artist.albums.length)} · ${l10n.trackCount(artist.tracks.length)}',
          onBack: onBack,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              if (artist.albums.isNotEmpty) ...[
                sectionTitle(l10n.sidebarAlbums),
                const SizedBox(height: 10),
                _AlbumGrid(
                  albums: artist.albums,
                  l10n: l10n,
                  onOpenAlbum: onOpenAlbum,
                ),
                const SizedBox(height: 22),
              ],
              sectionTitle(l10n.allTracks),
              const SizedBox(height: 8),
              ...artist.tracks.asMap().entries.map(
                    (e) => AppAnim.listEntrance(
                      TrackRow(
                        player: player,
                        track: e.value,
                        index: e.key,
                        isCurrent: e.value.id == currentId,
                        isPlaying: playing && e.value.id == currentId,
                        onPlay: (i) => player.playFrom(artist.tracks, i),
                      ),
                      e.key,
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 专辑详情：头部（含「播放整张」）+ 按音轨号排序的曲目列表。
class AlbumDetail extends ConsumerWidget {
  final PlayerController player;
  final String albumKey;
  final VoidCallback onBack;
  const AlbumDetail({
    super.key,
    required this.player,
    required this.albumKey,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryProvider);
    ref.watch(currentIndexProvider);
    final playing = ref.watch(playingProvider).value ?? false;
    final l10n = AppLocalizations.of(context);
    final idx = MediaIndex.build(player.library);
    final album = idx.albumByKey(albumKey);
    if (album == null) return detailEmpty(l10n);
    final name = album.name.isEmpty ? l10n.albumUnknown : album.name;
    final artistName =
        album.artist.isEmpty ? l10n.artistUnknown : album.artist;
    final tracks = album.orderedTracks;
    final accent = AccentScope.of(context);
    final currentId = player.currentTrack?.id;
    return Column(
      children: [
        DetailHeader(
          coverUrl: album.coverUrl,
          seed: album.key,
          title: name,
          subtitle: '$artistName · ${l10n.trackCount(tracks.length)}',
          onBack: onBack,
          action: FilledButton.icon(
            onPressed: () => player.playFrom(tracks, 0),
            icon: const Icon(LucideIcons.play, size: 16),
            label: Text(l10n.playAlbum),
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: accent.onAccent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: tracks.asMap().entries.map(
                  (e) => AppAnim.listEntrance(
                    TrackRow(
                      player: player,
                      track: e.value,
                      index: e.key,
                      isCurrent: e.value.id == currentId,
                      isPlaying: playing && e.value.id == currentId,
                      onPlay: (i) => player.playFrom(tracks, i),
                    ),
                    e.key,
                  ),
                ).toList(),
          ),
        ),
      ],
    );
  }
}
