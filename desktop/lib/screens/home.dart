import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../screens/network_dialogs.dart';
import 'settings.dart';
import '../services/cover.dart';
import '../services/lyrics.dart';
import '../services/network_source_config.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';
import '../services/subsonic_service.dart';
import '../services/webdav_service.dart';

// 单色板来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _surface2 = kSurface2;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late final PlayerController player;
  StreamSubscription<String>? _errorSub;

  @override
  void initState() {
    super.initState();
    player = ref.read(playerControllerProvider);
    // 持久化/导入等失败统一走 errorStream → SnackBar（此前静默 debugPrint，
    // 用户对「曲库写入失败」毫无感知）。mounted 守卫避免 dispose 后弹窗。
    _errorSub = player.errorStream.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }

  final _kbFocus = FocusNode();
  final _searchFocus = FocusNode();
  final _searchCtrl = TextEditingController();

  String _viewMode = 'all'; // 'all' | 'favorites' | 'pl:<id>'
  String _query = '';
  int _sort = 0; // 0 default, 1 title, 2 artist

  @override
  void dispose() {
    _errorSub?.cancel();
    _kbFocus.dispose();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Track> get _baseList {
    if (_viewMode == 'favorites') {
      return player.library
          .where((t) => player.favoriteIds.contains(t.id))
          .toList();
    }
    if (_viewMode.startsWith('pl:')) {
      final id = _viewMode.substring(3);
      final pl = player.playlists.where((p) => p.id == id).firstOrNull;
      if (pl != null) return player.tracksOfPlaylist(pl);
    }
    if (_viewMode.startsWith('src:')) {
      final src = _viewMode.substring(4);
      return player.library.where((t) => t.source.name == src).toList();
    }
    return player.library;
  }

  List<Track> get _visible {
    var l = _baseList;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      l = l
          .where((t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q))
          .toList();
    }
    if (_sort == 1) {
      l = [...l]..sort((a, b) => a.title.compareTo(b.title));
    } else if (_sort == 2) {
      l = [...l]..sort((a, b) => a.artist.compareTo(b.artist));
    }
    return l;
  }

  String get _viewTitle {
    final l10n = AppLocalizations.of(context);
    if (_query.isNotEmpty) return l10n.search;
    if (_viewMode == 'favorites') return l10n.viewFavorites;
    if (_viewMode.startsWith('pl:')) {
      final id = _viewMode.substring(3);
      return player.playlists.where((p) => p.id == id).firstOrNull?.name ??
          l10n.viewPlaylists;
    }
    if (_viewMode.startsWith('src:')) {
      final src = _viewMode.substring(4);
      return switch (src) {
        'webdav' => 'WebDAV',
        'nas' => 'NAS',
        'subsonic' => 'Subsonic',
        _ => l10n.viewLibrary,
      };
    }
    return l10n.viewLibrary;
  }

  void _selectView(String mode) => setState(() => _viewMode = mode);

  void _focusSearch() => _searchFocus.requestFocus();

  /// 选择本地音乐文件夹并加入曲库（路径由 PlayerController 持久化）。
  Future<void> _addFolder() async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    await player.addFolder(dir);
    if (_viewMode != 'all') setState(() => _viewMode = 'all');
  }

  void _seekBy(Duration delta) {
    final max = player.duration;
    final target = player.position + delta;
    player.seek(target < Duration.zero
        ? Duration.zero
        : (max > Duration.zero && target > max ? max : target));
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_searchFocus.hasFocus) {
      if (e.logicalKey == LogicalKeyboardKey.escape) _searchFocus.unfocus();
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.space) {
      player.togglePlay();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 5));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -5));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收藏/播放列表/曲库变化，使各视图随状态实时刷新
    ref.watch(favoritesProvider);
    ref.watch(playlistsProvider);
    ref.watch(libraryProvider);
    final visible = _visible;
    // 当前强调色：Phase 1 与 mobile 一致使用 accentFallback（橙红）；
    // Phase 2 封面提取管线落地后将改为「当前曲目封面主色」（封面主色强调）。
    final accent = AppTheme.accentFallback;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
      },
      child: Actions(
        actions: {
          _FocusSearchIntent: CallbackAction(
            onInvoke: (_) {
              _focusSearch();
              return null;
            },
          ),
        },
        child: KeyboardListener(
          focusNode: _kbFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: AccentScope(
            accent: accent,
            child: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        // 侧栏 220 + 列表最小 340 + 播放面板 340：宽度不足时
                        // 隐藏右侧播放面板（对齐 Spotify 窄窗口只留侧栏+列表）
                        final showNowPlaying = c.maxWidth >= 900;
                        return Row(
                          children: [
                            _Sidebar(
                              player: player,
                              viewMode: _viewMode,
                              onSelect: _selectView,
                              onCreate: _createPlaylist,
                              onAddFolder: _addFolder,
                            ),
                            Expanded(
                              child: _LibraryView(
                                player: player,
                                tracks: visible,
                                title: _viewTitle,
                                query: _query,
                                onQuery: (v) => setState(() => _query = v),
                                sort: _sort,
                                onSort: (v) => setState(() => _sort = v),
                                searchFocus: _searchFocus,
                                searchCtrl: _searchCtrl,
                                onPlay: (i) => player.playFrom(visible, i),
                                onAddFolder: _addFolder,
                              ),
                            ),
                            if (showNowPlaying) _NowPlaying(player: player),
                          ],
                        );
                      },
                    ),
                  ),
                  _TransportBar(player: player),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createPlaylist() async {
    final l10n = AppLocalizations.of(context);
    final name = await _askName(
        context, l10n.dlgNewPlaylistTitle, l10n.dlgNameHintPlaylist);
    if (name != null && name.trim().isNotEmpty) {
      await player.createPlaylist(name.trim());
    }
  }

  Future<String?> _askName(
      BuildContext context, String title, String hint) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _surface,
          title: Text(title, style: const TextStyle(color: _onSurface)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: _onSurface),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: _onSurfaceVariant),
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _border),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _onSurfaceVariant),
              ),
            ),
            onSubmitted: (value) => Navigator.pop(ctx, ctrl.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.btnCancel,
                  style: const TextStyle(color: _onSurfaceVariant)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(l10n.btnOk,
                  style: const TextStyle(color: _onSurface)),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }
}

class _Sidebar extends ConsumerWidget {
  final PlayerController player;
  final String viewMode;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final VoidCallback onAddFolder;

  const _Sidebar({
    required this.player,
    required this.viewMode,
    required this.onSelect,
    required this.onCreate,
    required this.onAddFolder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 订阅收藏/播放列表/曲库变化以刷新计数与列表
    ref.watch(favoritesProvider);
    ref.watch(playlistsProvider);
    ref.watch(libraryProvider);
    ref.watch(networkConfigProvider);
    ref.watch(nasStateProvider);
    final l10n = AppLocalizations.of(context);
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(right: BorderSide(color: _border)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 22, 20, 14),
            child: Text(l10n.sidebarLocalMusic,
                style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: _onSurface,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3)),
          ),
          _NavItem(
            icon: LucideIcons.music,
            label: l10n.sidebarLibrary,
            active: viewMode == 'all',
            onTap: () => onSelect('all'),
          ),
          _NavItem(
            icon: LucideIcons.folderInput,
            label: l10n.sidebarAddFolder,
            active: false,
            onTap: onAddFolder,
          ),
          _NavItem(
            icon: LucideIcons.heart,
            label: l10n.sidebarFavorites,
            trailing: player.favoriteIds.isEmpty
                ? null
                : '${player.favoriteIds.length}',
            active: viewMode == 'favorites',
            onTap: () => onSelect('favorites'),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(l10n.sidebarNetworkSources,
                style: TextStyle(color: _onSurfaceVariant, fontSize: 12)),
          ),
          _NavItem(
            icon: LucideIcons.globe,
            label: 'WebDAV',
            trailingActions: _sourceActionButtons(context, TrackSource.webdav),
            active: viewMode == 'src:webdav',
            onTap: () => onSelect('src:webdav'),
          ),
          _NavItem(
            icon: LucideIcons.server,
            label: 'NAS (SMB)',
            trailingActions: _sourceActionButtons(context, TrackSource.nas),
            active: viewMode == 'src:nas',
            onTap: () => onSelect('src:nas'),
          ),
          _NavItem(
            icon: LucideIcons.radio,
            label: 'Subsonic',
            trailingActions: _sourceActionButtons(context, TrackSource.subsonic),
            active: viewMode == 'src:subsonic',
            onTap: () => onSelect('src:subsonic'),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(l10n.sidebarPlaylists,
                style: TextStyle(color: _onSurfaceVariant, fontSize: 12)),
          ),
          // 播放列表数量少，内联渲染即可（shrinkWrap）；整栏已在
          // SingleChildScrollView 内，矮窗口时侧栏整体可滚动、不再溢出。
          ListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: player.playlists
                .map(
                  (pl) => _NavItem(
                    icon: LucideIcons.listMusic,
                    label: pl.name,
                    trailing: '${pl.trackIds.length}',
                    active: viewMode == 'pl:${pl.id}',
                    onTap: () => onSelect('pl:${pl.id}'),
                  ),
                )
                .toList(),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onCreate,
                icon: const Icon(LucideIcons.plus, size: 16),
                label: Text(l10n.btnNewPlaylist),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _onSurfaceVariant,
                  side: const BorderSide(color: _border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(player: player)),
                ),
                icon: const Icon(LucideIcons.settings, size: 16),
                label: Text(l10n.settingsTitle),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _onSurfaceVariant,
                  side: const BorderSide(color: _border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }



  void _openNetwork(BuildContext context, TrackSource source) {
    showDialog<void>(
      context: context,
      builder: (ctx) => NetworkConfigDialog(source: source, player: player),
    );
  }

  /// 侧边栏网络音源项的操作按钮：已配置显示「刷新」+「配置」，
  /// 未配置仅显示「配置」引导入口。按钮设为紧凑约束以缩小两个图标的间距。
  List<Widget> _sourceActionButtons(BuildContext context, TrackSource source) {
    final l10n = AppLocalizations.of(context);
    final configured = switch (source) {
      TrackSource.webdav => WebdavService.isConfigured,
      TrackSource.nas => NetworkSourceConfig.instance.nasHost != null,
      TrackSource.subsonic => SubsonicService.isConfigured,
      TrackSource.local => false,
    };
    final buttons = <Widget>[
      if (configured)
        IconButton(
          icon: const Icon(LucideIcons.refreshCw, size: 15),
          color: AppTheme.textTertiary,
          tooltip: l10n.tooltipRescan,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          splashRadius: 16,
          onPressed: () => _refreshSource(context, player, source),
        ),
      IconButton(
        icon: const Icon(LucideIcons.settings, size: 15),
        color: AppTheme.textTertiary,
        tooltip: l10n.tooltipConfig,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        splashRadius: 16,
        onPressed: () => _openNetwork(context, source),
      ),
    ];
    return buttons;
  }

  /// 侧边栏直接重扫某网络音源（不进配置对话框），用 SnackBar 反馈结果。
  Future<void> _refreshSource(
    BuildContext context,
    PlayerController player,
    TrackSource source,
  ) async {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.snackRescanning)));
    try {
      final tracks = switch (source) {
        TrackSource.webdav => await player.importWebdav(),
        TrackSource.nas => await player.importNas(),
        TrackSource.subsonic => await player.importSubsonic(),
        TrackSource.local => const <Track>[],
      };
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.refreshedCount(tracks.length))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.refreshFailed(e))));
      }
    }
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final bool active;
  final VoidCallback onTap;
  final List<Widget>? trailingActions;

  const _NavItem({
    required this.icon,
    required this.label,
    this.trailing,
    this.active = false,
    required this.onTap,
    this.trailingActions,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(icon,
              size: 17, color: active ? accent : AppTheme.textTertiary),
          const SizedBox(width: 11),
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: active ? _onSurface : _onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ),
          if (trailing != null)
            Text(trailing!,
                style: const TextStyle(
                    color: AppTheme.textTertiary, fontSize: 11)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          // 选中态左侧强调色条
          Container(
            width: 3,
            height: 26,
            decoration: BoxDecoration(
              color: active ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Material(
              color: active ? _surface2 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: body,
              ),
            ),
          ),
          if (trailingActions != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: trailingActions!,
              ),
            ),
        ],
      ),
    );
  }
}

class _LibraryView extends ConsumerWidget {
  final PlayerController player;
  final List<Track> tracks;
  final String title;
  final String query;
  final ValueChanged<String> onQuery;
  final int sort;
  final ValueChanged<int> onSort;
  final FocusNode searchFocus;
  final TextEditingController searchCtrl;
  final ValueChanged<int> onPlay;
  final VoidCallback onAddFolder;

  const _LibraryView({
    required this.player,
    required this.tracks,
    required this.title,
    required this.query,
    required this.onQuery,
    required this.sort,
    required this.onSort,
    required this.searchFocus,
    required this.searchCtrl,
    required this.onPlay,
    required this.onAddFolder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 订阅当前曲目变化，刷新「正在播放」高亮
    ref.watch(currentIndexProvider);
    final l10n = AppLocalizations.of(context);
    final currentId = player.currentTrack?.id;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: _surface,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: _border),
                  ),
                  child: Row(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: Icon(LucideIcons.search,
                            size: 18, color: AppTheme.textTertiary),
                      ),
                      Expanded(
                        child: TextField(
                          focusNode: searchFocus,
                          controller: searchCtrl,
                          onChanged: onQuery,
                          style: const TextStyle(color: _onSurface, fontSize: 13.5),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: l10n.searchHint,
                            hintStyle: const TextStyle(color: _onSurfaceVariant),
                            contentPadding: const EdgeInsets.only(bottom: 2),
                          ),
                        ),
                      ),
                      if (query.isNotEmpty)
                        IconButton(
                          icon: const Icon(LucideIcons.x,
                              size: 16, color: AppTheme.textTertiary),
                          onPressed: () {
                            searchCtrl.clear();
                            onQuery('');
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _SortMenu(sort: sort, onSort: onSort),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
          child: Row(
            children: [
              Text(title,
                  style: const TextStyle(
                      color: _onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text(l10n.trackCount(tracks.length),
                  style: const TextStyle(
                      color: _onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: Builder(
            builder: (c) {
              if (tracks.isEmpty) {
                // 整个曲库为空（还没添加过文件夹）：给出引导，而非假数据
                if (query.isEmpty && player.library.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(LucideIcons.folderOpen,
                            size: 46, color: AppTheme.textTertiary),
                        const SizedBox(height: 16),
                        Text(l10n.libraryEmpty,
                            style: const TextStyle(
                                color: _onSurface, fontSize: 16)),
                        const SizedBox(height: 6),
                        Text(l10n.addFolderToStart,
                            style: const TextStyle(
                                color: _onSurfaceVariant, fontSize: 13)),
                        const SizedBox(height: 18),
                        OutlinedButton.icon(
                          onPressed: onAddFolder,
                          icon: const Icon(LucideIcons.plus, size: 16),
                          label: Text(l10n.sidebarAddFolder),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _onSurface,
                            side: const BorderSide(color: _border),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return Center(
                  child: Text(l10n.noMatch,
                      style: const TextStyle(color: _onSurfaceVariant)),
                );
              }
              return ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (c, i) {
                  final t = tracks[i];
                  final selected = t.id == currentId;
                  return _TrackRow(
                    player: player,
                    track: t,
                    index: i,
                    selected: selected,
                    onPlay: onPlay,
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

class _SortMenu extends StatelessWidget {
  final int sort;
  final ValueChanged<int> onSort;
  const _SortMenu({required this.sort, required this.onSort});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<int>(
      color: _surface,
      icon: const Icon(LucideIcons.arrowDownUp,
          size: 18, color: AppTheme.textTertiary),
      tooltip: l10n.tooltipSort,
      onSelected: onSort,
      itemBuilder: (c) => [
        PopupMenuItem(value: 0, child: _SortItem(l10n.sortDefault)),
        PopupMenuItem(value: 1, child: _SortItem(l10n.sortByTitle)),
        PopupMenuItem(value: 2, child: _SortItem(l10n.sortByArtist)),
      ],
    );
  }
}

class _SortItem extends StatelessWidget {
  final String label;
  const _SortItem(this.label);
  @override
  Widget build(BuildContext context) =>
      Text(label, style: const TextStyle(color: _onSurface, fontSize: 13));
}

class _TrackRow extends StatelessWidget {
  final PlayerController player;
  final Track track;
  final int index;
  final bool selected;
  final ValueChanged<int> onPlay;

  const _TrackRow({
    required this.player,
    required this.track,
    required this.index,
    required this.selected,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final l10n = AppLocalizations.of(context);
    final badge = track.isNetwork
        ? track.source.short
        : (track.filePath != null
            ? p.extension(track.filePath!)
                .toUpperCase()
                .replaceFirst('.', '')
            : l10n.simulated);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onPlay(index),
        child: Container(
          decoration: selected
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(color: accent, width: 2),
                  ),
                  color: accent.withValues(alpha: 0.05),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              children: [
                CoverArt(
                  key: ValueKey('row-${track.coverUrl ?? track.id}'),
                  seed: track.id, coverUrl: track.coverUrl, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: selected ? accent : _onSurface,
                              fontSize: 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(_sourceIcon(track.source),
                              size: 12, color: AppTheme.textTertiary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _onSurfaceVariant, fontSize: 12)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: _border),
                ),
                child: Text(badge,
                    style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        color: _onSurfaceVariant,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3)),
              ),
              const SizedBox(width: 10),
              _FavoriteButton(player: player, track: track),
              PopupMenuButton<String>(
                icon: const Icon(LucideIcons.moreVertical,
                    size: 18, color: AppTheme.textTertiary),
                color: _surface,
                itemBuilder: (c) => [
                  PopupMenuItem(
                    value: 'fav',
                    child: Text(
                        player.isFavorite(track) ? l10n.favRemove : l10n.favAdd,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                  PopupMenuItem(
                    value: 'next',
                    child: Text(l10n.playNext,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                  PopupMenuItem(
                    value: 'add',
                    child: Text(l10n.addToPlaylist,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                  PopupMenuItem(
                    value: 'play',
                    child: Text(l10n.playNow,
                        style: const TextStyle(color: _onSurface, fontSize: 13)),
                  ),
                ],
                onSelected: (v) {
                  switch (v) {
                    case 'fav':
                      player.toggleFavorite(track);
                    case 'next':
                      player.playNext(track);
                    case 'add':
                      _openAddMenu(context, track);
                    case 'play':
                      onPlay(index);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  void _openAddMenu(BuildContext context, Track track) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text(l10n.dlgAddToPlaylist,
            style: const TextStyle(color: _onSurface)),
        content: SizedBox(
          width: 300,
          child: Consumer(
            builder: (context, ref, _) {
              // 订阅播放列表变化，使对话框内列表实时刷新
              ref.watch(playlistsProvider);
              final pls = player.playlists;
              return ListView(
                shrinkWrap: true,
                children: [
                  ...pls.map(
                    (pl) => ListTile(
                      title: Text(pl.name,
                          style: const TextStyle(color: _onSurface)),
                      subtitle: Text(l10n.trackCount(pl.trackIds.length),
                          style:
                              const TextStyle(color: _onSurfaceVariant)),
                      onTap: () {
                        player.addToPlaylist(pl.id, track.id);
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                  ListTile(
                    leading: const Icon(LucideIcons.plus,
                        color: AppTheme.textTertiary),
                    title: Text(l10n.newPlaylist,
                        style: const TextStyle(color: _onSurface)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final name = await _askNewPlaylist(context, track);
                      if (name != null && name.trim().isNotEmpty) {
                        await player.createPlaylist(name.trim());
                        await player.addToPlaylist(
                            player.playlists.last.id, track.id);
                      }
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<String?> _askNewPlaylist(BuildContext context, Track track) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _surface,
          title: Text(l10n.dlgNewPlaylistTitle,
              style: const TextStyle(color: _onSurface)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: _onSurface),
            decoration: InputDecoration(
              hintText: l10n.playlistNameHint,
              hintStyle: const TextStyle(color: _onSurfaceVariant),
              enabledBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: _border)),
              focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: _onSurfaceVariant)),
            ),
            onSubmitted: (value) => Navigator.pop(ctx, ctrl.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.btnCancel,
                  style: const TextStyle(color: _onSurfaceVariant)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(l10n.btnOk,
                  style: const TextStyle(color: _onSurface)),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }
}

class _FavoriteButton extends ConsumerWidget {
  final PlayerController player;
  final Track track;
  const _FavoriteButton({required this.player, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(favoritesProvider);
    final fav = player.isFavorite(track);
    return IconButton(
      icon: Icon(
        fav ? LucideIcons.heart : LucideIcons.heart,
        size: 17,
        color: fav ? AppTheme.danger : AppTheme.textTertiary,
        fill: fav ? 1.0 : 0.0,
      ),
      onPressed: () => player.toggleFavorite(track),
    );
  }
}

class _NowPlaying extends ConsumerWidget {
  final PlayerController player;
  const _NowPlaying({required this.player});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch libraryProvider 让封面异步提取完成后面板也能刷新
    ref.watch(currentIndexProvider);
    ref.watch(libraryProvider);
    final l10n = AppLocalizations.of(context);
    final track = player.currentTrack;
    return Container(
      width: 340,
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(left: BorderSide(color: _border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: CoverArt(
                key: ValueKey('np-${track?.coverUrl ?? track?.id ?? 'empty'}'),
                seed: track?.id ?? 'empty',
                coverUrl: track?.coverUrl,
                size: 168,
                rounded: true,
              ),
            ),
            const SizedBox(height: 16),
            Text(track?.title ?? l10n.nowPlayingEmpty,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: _onSurface,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3)),
            const SizedBox(height: 4),
            Text(track?.artist ?? l10n.tapToStart,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 10),
            // BPM/Key 分析徽章（播放时后台分析，完成后经 analysisStream 刷新）
            StreamBuilder<String>(
              stream: player.analysisStream,
              builder: (context, _) =>
                  _AnalysisTags(player: player, track: track),
            ),
            const SizedBox(height: 14),
            _Progress(player: player),
            const SizedBox(height: 12),
            Expanded(child: _Lyrics(player: player)),
          ],
        ),
      ),
    );
  }
}

/// BPM / Key 分析徽章（对齐 mobile 播放页 _Tags）。无结果（未分析完/失败）
/// 时渲染为空，不占位；分析完成经 [PlayerController.analysisStream] 触发重建。
class _AnalysisTags extends StatelessWidget {
  final PlayerController player;
  final Track? track;
  const _AnalysisTags({required this.player, required this.track});

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) return const SizedBox.shrink();
    final a = player.getAnalysis(t.id);
    if (a == null) return const SizedBox.shrink();
    final chips = <Widget>[];
    if (a.bpm != null) chips.add(_chip('${a.bpm!.round()} BPM'));
    if (a.key != null && a.key!.isNotEmpty) chips.add(_chip(a.key!));
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _chip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _surface2,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _border),
        ),
        child: Text(label,
            style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: _onSurfaceVariant)),
      );
}

class _Progress extends ConsumerStatefulWidget {
  final PlayerController player;
  const _Progress({required this.player});

  @override
  ConsumerState<_Progress> createState() => _ProgressState();
}

class _ProgressState extends ConsumerState<_Progress> {
  /// 拖动中的本地值；null 表示未在拖动（显示真实播放位置）。
  /// 拖动过程不 seek 引擎，松手（onChangeEnd）才提交，避免每帧 FFI 调用。
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur = ref.watch(durationProvider).value ?? Duration.zero;
    final max = dur.inMilliseconds.toDouble();
    final shown = _dragMs ??
        (max > 0 ? pos.inMilliseconds.toDouble().clamp(0.0, max) : 0.0);
    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            thumbColor: accent,
            activeTrackColor: accent,
            inactiveTrackColor: _surface2,
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: shown,
            max: max > 0 ? max : 1,
            onChanged: (v) => setState(() => _dragMs = v),
            onChangeEnd: (v) {
              setState(() => _dragMs = null);
              widget.player.seek(Duration(milliseconds: v.toInt()));
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_fmt(Duration(
                milliseconds: (_dragMs ?? pos.inMilliseconds).toInt())),
                style: _timeStyle),
            Text(_fmt(dur), style: _timeStyle),
          ],
        ),
      ],
    );
  }

  static const _timeStyle =
      TextStyle(color: _onSurfaceVariant, fontSize: 12);
}

class _Lyrics extends ConsumerStatefulWidget {
  final PlayerController player;
  const _Lyrics({required this.player});

  @override
  ConsumerState<_Lyrics> createState() => _LyricsState();
}

class _LyricsState extends ConsumerState<_Lyrics> {
  final _ctrl = ScrollController();
  int _lastActive = -1;

  /// 每行歌词固定高度，用于计算 auto-scroll offset。
  static const _lineH = 40.0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lines = ref.watch(lyricsProvider).value ?? const <LyricLine>[];
    if (lines.isEmpty) {
      return Center(
        child: Text(l10n.noLyrics,
            style: const TextStyle(color: _onSurfaceVariant, fontSize: 13)),
      );
    }
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final active = activeLyricIndex(lines, pos);

    // 当前行变化时平滑滚动至居中位置
    if (active != _lastActive) {
      _lastActive = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_ctrl.hasClients || active < 0) return;
        final viewport = _ctrl.position.viewportDimension;
        final target =
            active * _lineH - (viewport - _lineH) / 2;
        _ctrl.animateTo(
          target.clamp(0.0, _ctrl.position.maxScrollExtent),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      });
    }

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0.0, 0.1, 0.9, 1.0],
      ).createShader(rect),
      child: ListView.builder(
        controller: _ctrl,
        padding: const EdgeInsets.symmetric(vertical: 50),
        itemCount: lines.length,
        itemBuilder: (c, i) {
          final isActive = i == active;
          final distance = (i - active).abs();
          return SizedBox(
            height: _lineH,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                lines[i].text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive
                      ? _onSurface
                      : distance <= 2
                          ? _onSurfaceVariant
                          : AppTheme.textTertiary,
                  fontWeight:
                      isActive ? FontWeight.w600 : FontWeight.w400,
                  fontSize: isActive ? 15.5 : 13,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TransportBar extends ConsumerStatefulWidget {
  final PlayerController player;
  const _TransportBar({required this.player});

  @override
  ConsumerState<_TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<_TransportBar> {
  /// 进度条拖动本地值（拖动中不 seek 引擎）。
  double? _seekDragMs;
  /// 音量条拖动本地值（拖动中实时下发引擎但不落盘，松手才持久化）。
  double? _volDrag;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final l10n = AppLocalizations.of(context);
    // 订阅模式/曲目变化，刷新 shuffle、循环、迷你封面等
    ref.watch(modeProvider);
    ref.watch(currentIndexProvider);
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur = ref.watch(durationProvider).value ?? Duration.zero;
    final playing = ref.watch(playingProvider).value ?? false;
    final max = dur.inMilliseconds.toDouble();
    final progress =
        _seekDragMs ?? (max > 0 ? pos.inMilliseconds.toDouble().clamp(0.0, max) : 0.0);
    final t = player.currentTrack;
    final accent = AccentScope.of(context);
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Column(
        children: [
          SliderTheme(
            data: SliderThemeData(
              thumbColor: accent,
              activeTrackColor: accent,
              inactiveTrackColor: _surface2,
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
            ),
            child: Slider(
              value: progress,
              max: max > 0 ? max : 1,
              onChanged: (v) => setState(() => _seekDragMs = v),
              onChangeEnd: (v) {
                setState(() => _seekDragMs = null);
                player.seek(Duration(milliseconds: v.toInt()));
              },
            ),
          ),
          LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              // 窄窗口逐级隐藏次要元素（对齐主流播放器做法：核心控制始终可见，
              // 优先隐藏音量条 → 歌曲信息 → 迷你封面 → 随机/循环）
              final showVolumeSlider = w >= 660;
              final showLeftInfo = w >= 540;
              final showCover = w >= 380;
              final showMode = w >= 420;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 18, 12),
                child: Row(
                  children: [
                    // Left: mini now-playing
                    if (showCover) ...[
                      CoverArt(
                        key: ValueKey('tpbar-${t?.coverUrl ?? t?.id ?? 'empty'}'),
                        seed: t?.id ?? 'empty',
                        coverUrl: t?.coverUrl,
                        size: 40),
                      const SizedBox(width: 12),
                    ],
                    if (showLeftInfo) ...[
                      Flexible(
                        child: SizedBox(
                          width: 200,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t?.title ?? l10n.nowPlayingEmpty,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: _onSurface, fontSize: 13)),
                              Text(t?.artist ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: _onSurfaceVariant, fontSize: 11.5)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    // Center: controls
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (showMode)
                            IconButton(
                              icon: Icon(
                                LucideIcons.shuffle,
                                size: 18,
                                color: player.shuffle
                                    ? accent
                                    : AppTheme.textTertiary,
                              ),
                              onPressed: player.toggleShuffle,
                            ),
                          IconButton(
                            icon: const Icon(LucideIcons.skipBack,
                                size: 22, color: AppTheme.textPrimary),
                            onPressed: player.previous,
                          ),
                          const SizedBox(width: 4),
                          // 圆形播放/暂停按钮（强调色底）
                          Material(
                            color: accent,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: player.togglePlay,
                              child: Container(
                                width: 42,
                                height: 42,
                                alignment: Alignment.center,
                                child: Icon(
                                  playing
                                      ? LucideIcons.pause
                                      : LucideIcons.play,
                                  size: 22,
                                  color: accent.onAccent,
                                  fill: playing ? 1.0 : 0.0,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(LucideIcons.skipForward,
                                size: 22, color: AppTheme.textPrimary),
                            onPressed: player.next,
                          ),
                          if (showMode)
                            IconButton(
                              icon: Icon(
                                player.repeatMode == RepeatMode.one
                                    ? LucideIcons.repeat1
                                    : LucideIcons.repeat,
                                size: 18,
                                color: player.repeatMode == RepeatMode.off
                                    ? AppTheme.textTertiary
                                    : accent,
                              ),
                              onPressed: player.cycleRepeat,
                            ),
                        ],
                      ),
                    ),
                    // Right: engine status + volume
                    if (!player.engineReady)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Tooltip(
                          message: player.engineInitError ?? l10n.engineNotLoaded,
                          child: const Icon(LucideIcons.alertCircle,
                              color: AppTheme.textTertiary, size: 18),
                        ),
                      ),
                    const Icon(LucideIcons.volume2,
                        color: AppTheme.textTertiary, size: 20),
                    const SizedBox(width: 8),
                    if (showVolumeSlider)
                      SizedBox(
                        width: 120,
                        child: SliderTheme(
                          data: SliderThemeData(
                            thumbColor: _onSurface,
                            activeTrackColor: _onSurface,
                            inactiveTrackColor: _surface2,
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            // 拖动中实时下发引擎（听觉反馈），松手才持久化——
                            // 避免拖动过程每帧写 SharedPreferences。
                            value: _volDrag ?? player.volume,
                            onChanged: (v) {
                              setState(() => _volDrag = v);
                              player.setVolume(v);
                            },
                            onChangeEnd: (_) {
                              setState(() => _volDrag = null);
                              player.persistVolume();
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 统一封面组件：优先显示真实封面图（对齐 mobile「内容带色」），
/// 无封面或加载失败时降级为确定性灰阶渐变占位。
///
/// [coverUrl] 同时支持本地缓存文件（[Image.file]，由封面提取管线写入）
/// 与远程地址（[Image.network]，如 Subsonic 直接提供的封面 URL）。
class CoverArt extends StatelessWidget {
  final String seed;
  final String? coverUrl;
  final double size;
  final bool rounded;
  const CoverArt({
    super.key,
    required this.seed,
    this.coverUrl,
    this.size = 48,
    this.rounded = true,
  });

  bool get _hasCover => coverUrl != null && coverUrl!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final radius = rounded ? size * 0.12 : 0.0;
    // 缩略图按展示尺寸解码缩放，避免大封面整图进内存（对齐 mobile cacheWidth 策略）
    final cacheWidth = (size * 2.5).round().clamp(128, 1024);
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: _hasCover
            ? _coverImage(radius, cacheWidth)
            : _gradientFallback(radius),
      ),
    );
  }

  Widget _coverImage(double radius, int cacheWidth) {
    final url = coverUrl!;
    final isRemote =
        url.startsWith('http://') || url.startsWith('https://');
    // 注意：cacheWidth 仅存在于 Image.file / Image.network 具名构造，
    // 默认 Image(image:) 构造不接受，故此处分别构造。
    final fallback = _gradientFallback(radius);
    final cacheW = cacheWidth;
    return isRemote
        ? Image.network(
            url,
            key: ValueKey(url),
            fit: BoxFit.cover,
            cacheWidth: cacheW,
            errorBuilder: (_, _, _) => fallback,
          )
        : Image.file(
            File(url),
            key: ValueKey(url),
            fit: BoxFit.cover,
            cacheWidth: cacheW,
            errorBuilder: (_, _, _) => fallback,
          );
  }

  Widget _gradientFallback(double radius) {
    final g = coverGradient(seed);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g,
        ),
      ),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: const RadialGradient(
                center: Alignment(-0.4, -0.5),
                radius: 0.9,
                colors: [Color(0x1AFFFFFF), Color(0x00000000)],
              ),
            ),
          ),
          Center(
            child: Icon(LucideIcons.music,
                color: Colors.white.withValues(alpha: 0.22),
                size: size * 0.4),
          ),
        ],
      ),
    );
  }
}

/// 来源图标映射（对齐 mobile SongTile._sourceIcon）：
/// NAS=硬盘、WebDAV=云、Subsonic=服务器、本地=音乐。
IconData _sourceIcon(TrackSource source) => switch (source) {
      TrackSource.nas => LucideIcons.hardDrive,
      TrackSource.webdav => LucideIcons.cloud,
      TrackSource.subsonic => LucideIcons.server,
      TrackSource.local => LucideIcons.music,
    };

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}
