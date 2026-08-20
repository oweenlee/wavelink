import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_anim.dart';
import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';
import '../widgets/search_field.dart';
import '../widgets/track_row.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

/// 曲库视图：搜索 + 排序 + 标题/计数 + 歌曲列表（对齐 mobile
/// `ui/features/library/views/library_page.dart` 的歌曲 Tab 职责）。
class LibraryView extends ConsumerWidget {
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

  const LibraryView({
    super.key,
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
    // 订阅当前曲目与播放状态，刷新「正在播放」高亮与封面指示器
    ref.watch(currentIndexProvider);
    final playing = ref.watch(playingProvider).value ?? false;
    final l10n = AppLocalizations.of(context);
    final currentId = player.currentTrack?.id;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Row(
            children: [
              Expanded(
                child: SearchField(
                  focusNode: searchFocus,
                  controller: searchCtrl,
                  onChanged: onQuery,
                ),
              ),
              const SizedBox(width: 10),
              SortMenu(
                sort: sort,
                onSort: onSort,
                labels: [
                  l10n.sortDefault,
                  l10n.sortByTitle,
                  l10n.sortByArtist,
                ],
              ),
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
                  // 列表入场交错动画（与 mobile AppAnim 同规格）：
                  // 仅前 11 项生效，懒加载回收重建不重播。
                  return AppAnim.listEntrance(
                    TrackRow(
                      player: player,
                      track: t,
                      index: i,
                      isCurrent: t.id == currentId,
                      isPlaying: playing && t.id == currentId,
                      onPlay: onPlay,
                    ),
                    i,
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
