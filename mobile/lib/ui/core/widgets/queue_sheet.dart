import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../l10n/app_localizations.dart';
import '../../../domain/models/song.dart';
import '../../features/playback/view_models/playback_controller.dart';
import '../../features/playback/view_models/queue_provider.dart';
import '../theme/app_theme.dart';
import 'album_cover.dart';
import 'sheet_shell.dart';
import 'now_playing_indicator.dart';

class QueueSheet extends ConsumerWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    final queueState = ref.watch(queueProvider);
    return SheetShell(
      title: l10n.queueTitle,
      builder: (scroll) {
        if (queueState.queue.isEmpty) {
          return Center(
            child: Text(
              l10n.queueEmpty,
              style: TextStyle(fontSize: 15, color: AppTheme.textTertiary),
            ),
          );
        }
        return ReorderableListView.builder(
          scrollController: scroll,
          padding: const EdgeInsets.only(top: 8, bottom: 80),
          itemCount: queueState.queue.length,
          onReorderItem: (o, n) => player.reorderQueue(o, n),
          itemBuilder: (ctx, i) {
            // 边界保护：删除/重排队列后 provider 立即 notify，而 ReorderableListView
            // 的拖动/消失动画还没走完，会以旧 itemCount 回调 itemBuilder → 越界
            if (i < 0 || i >= queueState.queue.length) {
              return SizedBox(key: ValueKey('stale_$i'));
            }
            final s = queueState.queue[i];
            final isCurrent = i == queueState.currentIndex;
            return Dismissible(
              key: ValueKey('q_${s.id}_$i'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: AppTheme.danger.withValues(alpha: 0.3),
                child: const Icon(
                  LucideIcons.trash2,
                  color: AppTheme.danger,
                ),
              ),
              onDismissed: (_) => player.removeFromQueue(i),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => player.playFromQueue(i),
                child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    _QueueCover(song: s, isCurrent: isCurrent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: isCurrent
                                  ? AppTheme.brand
                                  : AppTheme.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            s.artist,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      s.formattedDuration,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 队列行封面：有封面文件则显示缩略图（当前曲叠加播放指示），
/// 无封面用占位符——与曲库行 _AlbumArt 同一套逻辑
class _QueueCover extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  const _QueueCover({required this.song, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final f = song.coverUrl != null ? File(song.coverUrl!) : null;
    final hasCover = f != null && f.existsSync();
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: hasCover ? song.dominantColor : AppTheme.s2,
        borderRadius: BorderRadius.circular(8),
        border: hasCover ? null : Border.all(color: AppTheme.s4, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasCover)
            Image.file(
              f,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const CoverPlaceholder(size: 36),
            )
          else
            const CoverPlaceholder(size: 36),
          if (isCurrent)
            Container(
              color: Colors.black26,
              child: const Center(
                child: NowPlayingIndicator(
                  baseHeight: 4,
                  barScale: 8,
                  maxHeight: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
