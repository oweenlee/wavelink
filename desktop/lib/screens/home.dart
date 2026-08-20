import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';
import '../widgets/dialogs.dart';
import 'library_view.dart';
import 'media_views.dart';
import 'now_playing.dart';
import 'sidebar.dart';
import 'transport_bar.dart';

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

/// 主界面壳（对齐 mobile AppShell 的职责：导航容器 + 布局分派 +
/// 全局快捷键），具体视图拆分至 sidebar / library_view / media_views /
/// now_playing / transport_bar 各文件。
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

  /// 中间区按 viewMode 分派：艺术家 / 专辑索引与详情走新媒体视图，
  /// 其余（all / favorites / pl / src / 搜索）仍走原有曲库视图。
  Widget _centerView(List<Track> visible) {
    if (_viewMode == 'artists') {
      return ArtistsView(
        player: player,
        onOpenArtist: (k) => _selectView('artist:$k'),
      );
    }
    if (_viewMode == 'albums') {
      return AlbumsView(
        player: player,
        onOpenAlbum: (k) => _selectView('album:$k'),
      );
    }
    if (_viewMode.startsWith('artist:')) {
      final key = _viewMode.substring(7);
      return ArtistDetail(
        player: player,
        artistKey: key,
        onOpenAlbum: (k) => _selectView('album:$k'),
        onBack: () => _selectView('artists'),
      );
    }
    if (_viewMode.startsWith('album:')) {
      final key = _viewMode.substring(6);
      return AlbumDetail(
        player: player,
        albumKey: key,
        onBack: () => _selectView('albums'),
      );
    }
    return LibraryView(
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
    );
  }

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
                        final w = c.maxWidth;
                        // 三级响应式断点（对齐主流桌面播放器窗口适配）：
                        //  <720      → 侧栏收缩为图标条、隐藏播放面板（compact）
                        //  720–1000  → 完整侧栏 + 列表，无播放面板
                        //  >=1000    → 完整侧栏 + 列表 + 播放面板
                        final compact = w < 720;
                        final showNowPlaying = w >= 1000;
                        final sidebarW =
                            compact ? 60.0 : (w > 1400 ? 240.0 : 220.0);
                        final npW = w > 1400 ? 360.0 : 320.0;
                        return Row(
                          children: [
                            Sidebar(
                              player: player,
                              viewMode: _viewMode,
                              compact: compact,
                              width: sidebarW,
                              onSelect: _selectView,
                              onCreate: _createPlaylist,
                              onAddFolder: _addFolder,
                            ),
                            Expanded(child: _centerView(visible)),
                            if (showNowPlaying)
                              NowPlaying(player: player, width: npW),
                          ],
                        );
                      },
                    ),
                  ),
                  TransportBar(player: player),
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
    final name = await askNameDialog(
      context,
      title: l10n.dlgNewPlaylistTitle,
      hint: l10n.dlgNameHintPlaylist,
    );
    if (name != null && name.trim().isNotEmpty) {
      await player.createPlaylist(name.trim());
    }
  }
}
