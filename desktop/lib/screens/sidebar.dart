import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/network_source_config.dart';
import '../services/player_notifier.dart';
import '../services/player_providers.dart';
import '../services/subsonic_service.dart';
import '../services/webdav_service.dart';
import '../widgets/nav_item.dart';
import 'network_dialogs.dart';
import 'settings.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _border = kBorder;
const _onSurfaceVariant = kOnSurfaceVariant;

/// 应用侧栏（对齐 mobile AppShell 的导航职责，桌面形态为左栏）：
/// 曲库 / 收藏 / 艺术家 / 专辑 + 网络音源（含配置/重扫入口）+ 播放列表。
/// 窄窗口（<720px）由调用方传 [compact] 折叠为图标条。
class Sidebar extends ConsumerWidget {
  final PlayerNotifier player;
  final String viewMode;
  final bool compact;
  final double width;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final VoidCallback onAddFolder;

  const Sidebar({
    super.key,
    required this.player,
    required this.viewMode,
    this.compact = false,
    this.width = 220,
    required this.onSelect,
    required this.onCreate,
    required this.onAddFolder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 订阅收藏/播放列表/曲库变化以刷新计数与列表
    final favorites = ref.watch(playerProvider.select((s) => s.favoriteIds));
    final playlists = ref.watch(playerProvider.select((s) => s.playlists));
    ref.watch(playerProvider.select((s) => s.library));
    ref.watch(networkConfigProvider);
    ref.watch(nasStateProvider);
    final l10n = AppLocalizations.of(context);
    // compact 模式：侧栏收缩为图标条（Tooltip 悬浮提示，无文字标签 / 分区 /
    // 播放列表），对齐 Spotify 窄窗口折叠侧栏，最大化横向空间。
    if (compact) {
      return Container(
        width: width,
        decoration: const BoxDecoration(
          color: _surface,
          border: Border(right: BorderSide(color: _border)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 16),
            NavItemCompact(
              icon: LucideIcons.music,
              tooltip: l10n.sidebarLibrary,
              active: viewMode == 'all',
              onTap: () => onSelect('all'),
            ),
            NavItemCompact(
              icon: LucideIcons.heart,
              tooltip: l10n.sidebarFavorites,
              active: viewMode == 'favorites',
              onTap: () => onSelect('favorites'),
            ),
            NavItemCompact(
              icon: LucideIcons.mic,
              tooltip: l10n.sidebarArtists,
              active: viewMode == 'artists',
              onTap: () => onSelect('artists'),
            ),
            NavItemCompact(
              icon: LucideIcons.disc,
              tooltip: l10n.sidebarAlbums,
              active: viewMode == 'albums',
              onTap: () => onSelect('albums'),
            ),
            NavItemCompact(
              icon: LucideIcons.globe,
              tooltip: 'WebDAV',
              active: viewMode == 'src:webdav',
              onTap: () => onSelect('src:webdav'),
            ),
            NavItemCompact(
              icon: LucideIcons.server,
              tooltip: 'NAS',
              active: viewMode == 'src:nas',
              onTap: () => onSelect('src:nas'),
            ),
            NavItemCompact(
              icon: LucideIcons.radio,
              tooltip: 'Subsonic',
              active: viewMode == 'src:subsonic',
              onTap: () => onSelect('src:subsonic'),
            ),
            const Spacer(),
            NavItemCompact(
              icon: LucideIcons.settings,
              tooltip: l10n.settingsTitle,
              onTap: () => _openSettings(context),
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    }
    return Container(
      width: width,
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
                style: WlText.display(fontSize: 17)),
          ),
          NavItem(
            icon: LucideIcons.music,
            label: l10n.sidebarLibrary,
            active: viewMode == 'all',
            onTap: () => onSelect('all'),
          ),
          NavItem(
            icon: LucideIcons.folderInput,
            label: l10n.sidebarAddFolder,
            active: false,
            onTap: onAddFolder,
          ),
          NavItem(
            icon: LucideIcons.heart,
            label: l10n.sidebarFavorites,
            trailing: favorites.isEmpty ? null : '${favorites.length}',
            active: viewMode == 'favorites',
            onTap: () => onSelect('favorites'),
          ),
          NavItem(
            icon: LucideIcons.mic,
            label: l10n.sidebarArtists,
            active: viewMode == 'artists',
            onTap: () => onSelect('artists'),
          ),
          NavItem(
            icon: LucideIcons.disc,
            label: l10n.sidebarAlbums,
            active: viewMode == 'albums',
            onTap: () => onSelect('albums'),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(l10n.sidebarNetworkSources,
                style: TextStyle(color: _onSurfaceVariant, fontSize: 12)),
          ),
          NavItem(
            icon: LucideIcons.globe,
            label: 'WebDAV',
            trailingActions: _sourceActionButtons(context, TrackSource.webdav),
            active: viewMode == 'src:webdav',
            onTap: () => onSelect('src:webdav'),
          ),
          NavItem(
            icon: LucideIcons.server,
            label: 'NAS (SMB)',
            trailingActions: _sourceActionButtons(context, TrackSource.nas),
            active: viewMode == 'src:nas',
            onTap: () => onSelect('src:nas'),
          ),
          NavItem(
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
            children: playlists
                .map(
                  (pl) => NavItem(
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
                onPressed: () => _openSettings(context),
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

  void _openSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
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
    PlayerNotifier player,
    TrackSource source,
  ) async {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.snackRescanning)));
    try {
      final tracks = await switch (source) {
        TrackSource.webdav => player.importWebdav(),
        TrackSource.nas => player.importNas(),
        TrackSource.subsonic => player.importSubsonic(),
        TrackSource.local => Future.value(const <Track>[]),
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
