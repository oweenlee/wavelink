import 'dart:async';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_anim.dart';
import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../services/player_notifier.dart';
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
  final PlayerNotifier player;
  const TransportBar({super.key, required this.player});

  @override
  ConsumerState<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<TransportBar> {
  /// 进度条拖动本地值（拖动中不 seek 引擎）。
  double? _seekDragMs;
  /// 音量条拖动本地值（拖动中实时下发引擎但不落盘，松手才持久化）。
  double? _volDrag;

  /// 睡眠定时器截止时刻；null = 未启用。
  DateTime? _sleepDeadline;
  Timer? _sleepTicker;

  void _setSleepTimer(int? minutes) {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    if (minutes == null) {
      setState(() => _sleepDeadline = null);
      return;
    }
    setState(() => _sleepDeadline = DateTime.now().add(Duration(minutes: minutes)));
    // 每秒刷新剩余时间显示；到点暂停播放（若已在播放）
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      final remain = _sleepDeadline?.difference(DateTime.now());
      if (remain == null || remain.isNegative) {
        t.cancel();
        if (!mounted) return;
        setState(() => _sleepDeadline = null);
        final st = ref.read(playerProvider);
        if (st.playing) widget.player.togglePlay();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).sleepDone)),
        );
      } else {
        setState(() {});
      }
    });
  }

  String _sleepRemainText() {
    final r = _sleepDeadline!.difference(DateTime.now());
    return '${r.inMinutes}:${(r.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _sleepTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final l10n = AppLocalizations.of(context);
    // select 精细订阅：各控件只在自己关心的状态变化时重建
    final st = ref.watch(playerProvider);
    final pos = st.position;
    final dur = st.duration;
    final playing = st.playing;
    final max = dur.inMilliseconds.toDouble();
    final progress =
        _seekDragMs ?? (max > 0 ? pos.inMilliseconds.toDouble().clamp(0.0, max) : 0.0);
    final t = st.currentTrack;
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
              // 窄窗口逐级隐藏次要元素
              final showVolumeSlider = w >= 760;
              final showLeftInfo = w >= 600; // 左侧固定占 252px，需给中间控制组留足空间
              final showCover = w >= 380;
              final showMode = w >= 420;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 18, 12),
                child: Row(
                  children: [
                    // 左侧：封面 + 歌曲信息（固定宽度，不挤压中间）
                    SizedBox(
                      width: showCover ? 252 : 0, // 40(封面)+12(间距)+200(标题)
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showCover) ...[
                            CoverArt(
                              key: ValueKey('tpbar-${t?.coverUrl ?? t?.id ?? 'empty'}'),
                              seed: t?.id ?? 'empty',
                              coverUrl: t?.coverUrl,
                              size: 40),
                            const SizedBox(width: 12),
                          ],
                          if (showLeftInfo)
                            SizedBox(
                              width: 200,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
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
                      ),
                    ),
                    // 中间：控制按钮组（Expanded 居中，不受左右宽度影响）
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (showMode)
                            IconButton(
                              // 播放模式单按钮四态：顺序→随机→单曲循环→列表循环
                              icon: Icon(
                                st.shuffle
                                    ? Icons.shuffle
                                    : (st.repeatMode == RepeatMode.one
                                        ? Icons.repeat_one
                                        : Icons.repeat),
                                size: 20,
                                color: (st.shuffle ||
                                        st.repeatMode != RepeatMode.off)
                                    ? accent
                                    : AppTheme.textTertiary,
                              ),
                              tooltip: st.shuffle
                                  ? l10n.modeShuffle
                                  : switch (st.repeatMode) {
                                      RepeatMode.one => l10n.modeRepeatOne,
                                      RepeatMode.all => l10n.modeRepeatAll,
                                      RepeatMode.off => l10n.modeSequential,
                                    },
                              onPressed: player.cyclePlayMode,
                            ),
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded,
                              size: 28, color: AppTheme.textPrimary),
                          tooltip: l10n.ttPrevious,
                          onPressed: player.previous,
                        ),
                        const SizedBox(width: 4),
                        // 圆形播放/暂停按钮（强调色底 + 阴影，对齐 mobile MiniPlayerBar）
                        Tooltip(
                          message: playing ? l10n.ttPause : l10n.ttPlay,
                          child: Container(
                            width: 42,
                            height: 42,
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
                            child: Material(
                              color: Colors.transparent,
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: player.togglePlay,
                                child: AnimatedSwitcher(
                                  duration: AppAnim.fast,
                                  switchInCurve: AppAnim.curve,
                                  switchOutCurve: AppAnim.curveIn,
                                  transitionBuilder: (child, anim) => ScaleTransition(
                                    scale: anim,
                                    child: FadeTransition(opacity: anim, child: child),
                                  ),
                                  child: Icon(
                                    key: ValueKey('play_$playing'),
                                    playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    size: 26,
                                    color: accent.onAccent,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded,
                              size: 28, color: AppTheme.textPrimary),
                          tooltip: l10n.ttNext,
                          onPressed: player.next,
                        ),
                        ],
                      ),
                    ),
                    // 右侧：引擎状态 + 睡眠定时 + 音量控制（宽度随内容：
                    // 基础=音量图标22+间距8；引擎异常时追加警告图标20+边距10；
                    // 睡眠定时按钮 w>=640 时追加约 40；音量条可见时再扩展到 180）
                    SizedBox(
                      width: (showVolumeSlider ? 200 : 30) +
                          (st.engineReady ? 0 : 30) +
                          (w >= 640 ? 48 : 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!st.engineReady)
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Tooltip(
                                message: st.engineInitError ?? l10n.engineNotLoaded,
                                child: const Icon(Icons.error_outline,
                                    color: AppTheme.textTertiary, size: 20),
                              ),
                            ),
                          // 睡眠定时器：到点自动暂停（窄窗口隐藏）
                          if (w >= 640)
                            PopupMenuButton<int?>(
                              tooltip: _sleepDeadline != null
                                  ? '${l10n.ttSleep} · ${_sleepRemainText()}'
                                  : l10n.ttSleep,
                              icon: Icon(
                                Icons.timer_outlined,
                                size: 20,
                                color: _sleepDeadline != null
                                    ? accent
                                    : AppTheme.textTertiary,
                              ),
                              onSelected: _setSleepTimer,
                              itemBuilder: (c) => [
                                PopupMenuItem(
                                  value: null,
                                  child: Text(l10n.sleepOff,
                                      style: const TextStyle(fontSize: 13)),
                                ),
                                ...const [15, 30, 60, 90].map((m) => PopupMenuItem(
                                      value: m,
                                      child: Text(l10n.sleepMinutes(m),
                                          style: const TextStyle(fontSize: 13)),
                                    )),
                              ],
                            ),
                          const Icon(Icons.volume_up,
                              color: AppTheme.textTertiary, size: 22),
                          const SizedBox(width: 8),
                          if (showVolumeSlider)
                            SizedBox(
                              width: 120,
                              child: SliderTheme(
                                data: wlSliderTheme(color: _onSurface),
                                child: Slider(
                                  value: _volDrag ?? st.volume,
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
