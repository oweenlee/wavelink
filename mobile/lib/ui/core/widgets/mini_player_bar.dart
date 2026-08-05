import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/playback/view_models/playback_controller.dart';
import '../../features/playback/view_models/audio_player_provider.dart';
import '../../features/playback/view_models/queue_provider.dart';
import '../theme/app_theme.dart';
import 'album_cover.dart';

class MiniPlayerBar extends ConsumerWidget {
  final VoidCallback? onTap;

  const MiniPlayerBar({super.key, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackControllerProvider);
    final playerState = ref.watch(playerProvider);
    final queueState = ref.watch(queueProvider);
    final song = queueState.currentSong;
    if (song == null) return const SizedBox.shrink();

    final accent = AppTheme.accentFallback;
    return AccentScope(
      accent: accent,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 2,
              width: double.infinity,
              child: Stack(
                children: [
                  Container(
                    height: 2,
                    color: AppTheme.textTertiary.withValues(alpha: 0.2),
                  ),
                  FractionallySizedBox(
                    widthFactor: playerState.progress.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ClipRRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.s2,
                    border: Border(
                      top: BorderSide(
                        color: AppTheme.edgeHighlight,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      WlCover(
                        coverUrl: song.coverUrl,
                        fallbackColor: song.dominantColor,
                        borderRadius: 6,
                        width: 36,
                        height: 36,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              song.artist,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // 播放/暂停 — 对齐播放页 _PlayBtn：accent 填充圆形 + 白色 Material 图标
                      GestureDetector(
                        onTap: () => player.togglePlay(),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.35),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                          child: Icon(
                            playerState.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 下一曲 — 对齐播放页 _TransportBtn：圆形 + 灰色 Material 填充图标
                      GestureDetector(
                        onTap: () => player.next(),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              Icons.skip_next,
                              color: AppTheme.textSecondary,
                              size: 22,
                            ),
                          ),
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
    );
  }
}
