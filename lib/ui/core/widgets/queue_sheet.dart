import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../features/playback/view_models/playback_provider.dart';
import '../theme/app_theme.dart';
import 'sheet_shell.dart';
import 'now_playing_indicator.dart';

class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    return SheetShell(
      title: l10n.queueTitle,
      builder: (scroll) {
        if (player.queue.isEmpty) {
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
          itemCount: player.queue.length,
          onReorderItem: (o, n) => player.reorderQueue(o, n),
          itemBuilder: (ctx, i) {
            final s = player.queue[i];
            final isCurrent = i == player.currentIndex;
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
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.gripHorizontal,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.s2,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: isCurrent
                          ? const Center(
                              child: NowPlayingIndicator(
                                baseHeight: 4,
                                barScale: 8,
                                maxHeight: 12,
                              ),
                            )
                          : null,
                    ),
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
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => player.removeFromQueue(i),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          LucideIcons.x,
                          size: 16,
                          color: AppTheme.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
