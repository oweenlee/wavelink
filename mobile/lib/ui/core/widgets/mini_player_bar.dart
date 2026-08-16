import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/playback/view_models/playback_controller.dart';
import '../../features/playback/view_models/audio_player_provider.dart';
import '../../features/playback/view_models/queue_provider.dart';
import '../../features/library/view_models/library_provider.dart';
import '../animations/app_animations.dart';
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
    ref.watch(libraryProvider); // 收藏状态变化时刷新迷你条爱心
    final song = queueState.currentSong;
    if (song == null) return const SizedBox.shrink();

    final accent = AppTheme.accentFallback;
    final barProgress = playerState.progress.clamp(0.0, 1.0);
    return AccentScope(
      accent: accent,
      // 首次出现：上滑淡入（Animate 状态随 rebuild 保留，只播一次）
      child: AppAnim.entrance(
        GestureDetector(
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
                    widthFactor: barProgress,
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
                      // 切歌封面交叉淡化（key=song.id，仅切歌时过渡）
                      AnimatedSwitcher(
                        duration: AppAnim.normal,
                        switchInCurve: AppAnim.curve,
                        switchOutCurve: AppAnim.curveIn,
                        child: WlCover(
                          key: ValueKey('mini_cover_${song.id}'),
                          coverUrl: song.coverUrl,
                          fallbackColor: song.dominantColor,
                          borderRadius: 6,
                          width: 36,
                          height: 36,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: AppAnim.normal,
                          switchInCurve: AppAnim.curve,
                          switchOutCurve: AppAnim.curveIn,
                          transitionBuilder: (child, anim) => SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.35),
                              end: Offset.zero,
                            ).animate(anim),
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: Column(
                            key: ValueKey('mini_info_${song.id}'),
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
                      ),
                      // 播放/暂停 — 图标 scale 过渡（对齐播放页 _PlayBtn）
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact(); // 轻震动反馈
                          player.togglePlay();
                        },
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
                          child: AnimatedSwitcher(
                            duration: AppAnim.fast,
                            switchInCurve: AppAnim.curve,
                            switchOutCurve: AppAnim.curveIn,
                            transitionBuilder: (child, anim) => ScaleTransition(
                              scale: anim,
                              child: FadeTransition(opacity: anim, child: child),
                            ),
                            child: Icon(
                              key: ValueKey('mini_play_${playerState.isPlaying}'),
                              playerState.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 收藏 — 播放按钮右侧，点击收藏/取消（与下一曲同款圆形按钮）
                      GestureDetector(
                        onTap: () => player.setFavorite(
                          song.id,
                          !player.isSongFavorite(song.id),
                        ),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              player.isSongFavorite(song.id)
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: player.isSongFavorite(song.id)
                                  ? AppTheme.danger
                                  : AppTheme.textSecondary,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 下一曲 — 对齐播放页 _TransportBtn：圆形 + 灰色 Material 填充图标
                      GestureDetector(
                        onTap: () => player.next(fromUser: true),
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
        slideY: 0.6,
      ),
    );
  }
}
