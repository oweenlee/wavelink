import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';
import '../widgets/cover_art.dart';
import '../widgets/wl_slider.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

/// 底部常驻传输栏（对齐 mobile MiniPlayerBar 的常驻控制职责，
/// 桌面形态为全宽底部条）：进度 seek + 迷你封面/标题 + 走带控制 +
/// 随机/循环模式 + 引擎状态 + 音量。
class TransportBar extends ConsumerStatefulWidget {
  final PlayerController player;
  const TransportBar({super.key, required this.player});

  @override
  ConsumerState<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<TransportBar> {
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
            data: wlSliderTheme(
                color: accent, trackHeight: 2.5, thumbRadius: 0),
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
              // 优先隐藏音量条 → 歌曲信息 → 迷你封面 → 随机/循环）。
              // 注意：传输栏横跨整个窗口宽度（与侧栏 Row 平级），
              // 并非「减去侧栏后的剩余」。左信息用 Flexible 可收缩（文字 ellipsis
              // 截断），中心控件与右端为固定宽；音量条需约 120px，故延后到
              // w>=760（左信息可收缩、中心+右端约 306px，760-34 padding-306≈420
              // 仍有余量）才显示，避免窄窗口横向溢出。
              final showVolumeSlider = w >= 760;
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
                    ],
                    // Center: controls
                    // 中心控件为固定最小宽（4×IconButton 48 + 播放 42 + 间隙），
                    // 用 flex:3 保证它在窄窗口分配上优先于左信息，避免被挤溢出；
                    // 左信息 Flexible 仍可收缩并以 ellipsis 截断。
                    Expanded(
                      flex: 3,
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
                          data: wlSliderTheme(color: _onSurface),
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
