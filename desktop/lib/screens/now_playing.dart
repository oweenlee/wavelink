import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_anim.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/lyrics.dart';
import '../services/player_notifier.dart';
import '../services/player_providers.dart';
import '../services/audio_settings_provider.dart';
import '../widgets/cover_art.dart';
import '../widgets/settings_controls.dart';
import '../widgets/wl_slider.dart';
import '../widgets/spectrum_visualizer.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

/// 右侧「正在播放」面板（对齐 mobile 播放页的信息密度布局，
/// 桌面形态为常驻侧栏）：封面 + 标题/艺术家 + 分析徽章 + 频谱 +
/// 进度条 + 歌词滚动；顶部可切换到「队列」视图（当前曲 + 剩余队列）。
class NowPlaying extends ConsumerStatefulWidget {
  final PlayerNotifier player;
  final double width;
  const NowPlaying({super.key, required this.player, this.width = 320});

  @override
  ConsumerState<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends ConsumerState<NowPlaying> {
  /// true = 显示队列视图；false = 正在播放视图。
  bool _showQueue = false;

  @override
  Widget build(BuildContext context) {
    // watch currentTrack：切歌 / 封面异步提取写回 state 后面板都能刷新
    final track = ref.watch(playerProvider.select((s) => s.currentTrack));
    final album = track?.album;
    final actualSampleRate =
        ref.watch(audioSettingsProvider.select((s) => s.actualSampleRate));
    final l10n = AppLocalizations.of(context);
    return Container(
      width: widget.width,
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(left: BorderSide(color: _border)),
      ),
      child: Column(
        children: [
          // 正在播放 / 队列 分段切换
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                _PanelTab(
                  label: l10n.npTabPlaying,
                  active: !_showQueue,
                  onTap: () {
                    if (_showQueue) setState(() => _showQueue = false);
                  },
                ),
                const SizedBox(width: 18),
                _PanelTab(
                  label: l10n.npTabQueue,
                  active: _showQueue,
                  onTap: () {
                    if (!_showQueue) setState(() => _showQueue = true);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _showQueue
                ? _QueueView(player: widget.player)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Tooltip(
                            message: l10n.npCoverZoomHint,
                            child: GestureDetector(
                              // 点击封面放大预览
                              onTap: () => _showCoverDialog(context, track),
                              child: CoverArt(
                                key: ValueKey(
                                    'np-${track?.coverUrl ?? track?.id ?? 'empty'}'),
                                seed: track?.id ?? 'empty',
                                coverUrl: track?.coverUrl,
                                size: 200,
                                rounded: true,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(track?.title ?? l10n.nowPlayingEmpty,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: WlText.display(fontSize: 17)),
                                  const SizedBox(height: 4),
                                  Text(track?.artist ?? l10n.tapToStart,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: _onSurfaceVariant,
                                          fontSize: 13)),
                                  // 专辑名（信息密度补齐：此前只显示标题/艺术家）
                                  if (album != null && album.isNotEmpty)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(top: 2),
                                      child: Text(album,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: _onSurfaceVariant,
                                              fontSize: 12)),
                                    ),
                                ],
                              ),
                            ),
                            // 当前曲一键收藏（此前面板纯展示零操作）
                            if (track != null)
                              _FavoriteButton(
                                  player: widget.player, track: track),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // BPM/Key 分析徽章（播放时后台分析，完成后经 analysisStream 刷新）
                        RepaintBoundary(
                          child: StreamBuilder<String>(
                            stream: widget.player.analysisStream,
                            builder: (context, _) => _AnalysisTags(
                                player: widget.player, track: track),
                          ),
                        ),
                        // 音质徽章：实际输出采样率 + 文件格式（hi-res 定位的核心读数）
                        if (track != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: TechChips(children: [
                              TechChip(
                                  label: 'SR',
                                  value: actualSampleRate != null
                                      ? '$actualSampleRate Hz'
                                      : '—'),
                              TechChip(
                                  label: 'FMT',
                                  value: _formatLabel(track)),
                            ]),
                          ),
                        const SizedBox(height: 14),
                        // 实时频谱（引擎 spectrum 事件驱动；暂停后自然衰减到零）
                        RepaintBoundary(
                            child: SpectrumVisualizer(
                                player: widget.player, height: 36)),
                        const SizedBox(height: 12),
                        RepaintBoundary(
                            child: _Progress(player: widget.player)),
                        const SizedBox(height: 12),
                        // Expanded 必须是 Column 直接子级，RepaintBoundary 放其内侧
                        Expanded(
                            child: RepaintBoundary(
                                child: _Lyrics(player: widget.player))),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }


  /// 封面放大预览：黑底大图 + 曲名/艺术家，点遮罩关闭。
  void _showCoverDialog(BuildContext context, Track? track) {
    if (track == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CoverArt(
                key: ValueKey('np-big-${track.coverUrl ?? track.id}'),
                seed: track.id,
                coverUrl: track.coverUrl,
                size: 420,
                rounded: true,
              ),
              const SizedBox(height: 14),
              Text(track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style:
                      WlText.display(fontSize: 20)),
              const SizedBox(height: 4),
              Text(track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  /// 文件格式标签：本地取扩展名，CUE 分轨标注 CUE，网络曲用音源短名。
  String _formatLabel(Track t) {
    if (t.isCueTrack) return 'CUE';
    if (!t.isNetwork && t.filePath != null) {
      final ext = t.filePath!.split('.').last.toUpperCase();
      return ext.isEmpty ? '—' : ext;
    }
    return t.source.short;
  }
}

/// BPM / Key 分析徽章（对齐 mobile 播放页 _Tags）。无结果（未分析完/失败）
/// 时渲染为空，不占位；分析完成经 [PlayerNotifier.analysisStream] 触发重建。
/// 当前曲收藏按钮（对齐曲目行 _FavoriteButton 视觉：实心红心高亮）。
class _FavoriteButton extends ConsumerWidget {
  final PlayerNotifier player;
  final Track track;
  const _FavoriteButton({required this.player, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playerProvider.select((s) => s.favoriteIds));
    final fav = player.isFavorite(track);
    final l10n = AppLocalizations.of(context);
    return IconButton(
      tooltip: fav ? l10n.favRemove : l10n.favAdd,
      // 对齐 mobile：Material 实心/描边爱心（Lucide 的 fill 参数不生效）
      icon: Icon(
        fav ? Icons.favorite : Icons.favorite_border,
        size: 20,
        color: fav ? AppTheme.danger : AppTheme.textTertiary,
      ),
      onPressed: () => player.toggleFavorite(track),
    );
  }
}

class _AnalysisTags extends StatelessWidget {
  final PlayerNotifier player;
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
          color: AppTheme.s3,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: Text(label, style: WlText.mono(fontSize: 10)),
      );
}

class _Progress extends ConsumerStatefulWidget {
  final PlayerNotifier player;
  const _Progress({required this.player});

  @override
  ConsumerState<_Progress> createState() => _ProgressState();
}

class _ProgressState extends ConsumerState<_Progress> {
  /// 拖动中的本地值；null 表示未在拖动（显示真实播放位置）。
  /// 拖动过程不 seek 引擎，松手（onChangeEnd）才提交，避免每帧 FFI 调用。
  double? _dragMs;

  /// 剩余时长（拖动中按拖动值计算；负值钳到 0）。
  Duration _remain(Duration pos, double? dragMs, Duration dur) {
    final ms = dragMs ?? pos.inMilliseconds.toDouble();
    final remain = dur.inMilliseconds - ms;
    return Duration(
        milliseconds: remain < 0 ? 0 : remain.round());
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final pos = ref.watch(playerProvider.select((s) => s.position));
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    final max = dur.inMilliseconds.toDouble();
    final shown = _dragMs ??
        (max > 0 ? pos.inMilliseconds.toDouble().clamp(0.0, max) : 0.0);
    return Column(
      children: [
        SliderTheme(
          data: wlSliderTheme(color: accent),
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
            Text(fmtDuration(Duration(
                milliseconds: (_dragMs ?? pos.inMilliseconds).toInt())),
                style: const TextStyle(color: _onSurfaceVariant, fontSize: 12)),
            // 剩余时长（桌面播放器惯例：总时长 → 剩余时长）
            Text('-${fmtDuration(_remain(pos, _dragMs, dur))}',
                style: const TextStyle(
                    color: _onSurfaceVariant, fontSize: 12)),
          ],
        ),
      ],
    );
  }
}

class _Lyrics extends ConsumerStatefulWidget {
  final PlayerNotifier player;
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
    final lines =
        ref.watch(playerProvider.select((s) => s.lyrics)) ?? const <LyricLine>[];
    if (lines.isEmpty) {
      return Center(
        child: Text(l10n.noLyrics,
            style: const TextStyle(color: _onSurfaceVariant, fontSize: 13)),
      );
    }
    final pos = ref.watch(playerProvider.select((s) => s.position));
    final active = activeLyricIndex(lines, pos);

    // 当前行变化时平滑滚动至居中位置
    // 尊重系统 reduced-motion 偏好：禁用动画时瞬移
    if (active != _lastActive) {
      _lastActive = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_ctrl.hasClients || active < 0) return;
        final viewport = _ctrl.position.viewportDimension;
        final target =
            active * _lineH - (viewport - _lineH) / 2;
        final clamped = target.clamp(0.0, _ctrl.position.maxScrollExtent);
        if (MediaQuery.of(context).disableAnimations) {
          _ctrl.jumpTo(clamped);
        } else {
          _ctrl.animateTo(
            clamped,
            duration: AppAnim.normal,
            curve: AppAnim.curve,
          );
        }
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
            // 点击歌词行跳转到该句时间点
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: InkWell(
                onTap: () => widget.player.seek(lines[i].time),
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
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 面板分段切换标签：文字 + 强调色下划线（对齐侧栏选中态语言）。
class _PanelTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _PanelTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color:
                        active ? _onSurface : _onSurfaceVariant)),
            const SizedBox(height: 5),
            Container(
              width: 24,
              height: 2,
              decoration: BoxDecoration(
                color: active ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 队列视图：当前曲目置顶（accent 高亮），其后为剩余队列。
/// 双击跳播、hover 单曲移除、顶部清空剩余队列。
class _QueueView extends ConsumerWidget {
  final PlayerNotifier player;
  const _QueueView({required this.player});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playerProvider.select((s) => s.queue));
    final qi = ref.watch(playerProvider.select((s) => s.queueIndex));
    final l10n = AppLocalizations.of(context);
    if (queue.isEmpty || qi == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.listMusic,
                size: 40, color: AppTheme.textTertiary),
            const SizedBox(height: 12),
            Text(l10n.queueEmpty,
                style: const TextStyle(color: _onSurface, fontSize: 14)),
            const SizedBox(height: 4),
            Text(l10n.queueEmptyHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: _onSurfaceVariant, fontSize: 12)),
          ],
        ),
      );
    }
    final remaining = queue.length - qi - 1;
    return Column(
      children: [
        // 剩余计数 + 清空
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 10, 4),
          child: Row(
            children: [
              Text(l10n.queueRemain(remaining),
                  style: const TextStyle(
                      color: _onSurfaceVariant, fontSize: 12)),
              const Spacer(),
              if (remaining > 0)
                IconButton(
                  icon: const Icon(LucideIcons.xCircle,
                      size: 16, color: AppTheme.textTertiary),
                  tooltip: l10n.queueClear,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  splashRadius: 14,
                  onPressed: player.clearQueue,
                ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            itemExtent: 44,
            itemCount: queue.length,
            // 拖拽回调：onReorderItem 已把 newIndex 换算为「移除旧项后的
            // 最终下标」，直接传给 moveInQueue。
            onReorderItem: (from, to) {
              if (to == from) return;
              player.moveInQueue(from, to);
            },
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) =>
                Material(
              color: AppTheme.background,
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              child: child,
            ),
            itemBuilder: (c, i) => ReorderableDragStartListener(
              key: ValueKey('drag-${queue[i].id}-$i'),
              index: i,
              child: _QueueTile(
                player: player,
                track: queue[i],
                index: i,
                isCurrent: i == qi,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 队列行：封面 + 标题/艺术家 + 时长；当前曲 accent 高亮 + 左条；
/// 双击跳播；hover 显示移除按钮。
class _QueueTile extends StatefulWidget {
  final PlayerNotifier player;
  final Track track;
  final int index;
  final bool isCurrent;

  const _QueueTile({
    required this.player,
    required this.track,
    required this.index,
    required this.isCurrent,
  });

  @override
  State<_QueueTile> createState() => _QueueTileState();
}

class _QueueTileState extends State<_QueueTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final l10n = AppLocalizations.of(context);
    final t = widget.track;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: widget.isCurrent
            ? accent.withValues(alpha: 0.06)
            : (_hovered ? AppTheme.highlight : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onDoubleTap: () => widget.player.playIndex(widget.index),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(
              children: [
                // 当前曲左条
                Container(
                  width: 2.5,
                  height: 22,
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: 8),
                CoverArt(
                  key: ValueKey('q-${t.coverUrl ?? t.id}'),
                  seed: t.id,
                  coverUrl: t.coverUrl,
                  size: 38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: widget.isCurrent
                                  ? accent
                                  : _onSurface,
                              fontWeight: widget.isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w400)),
                      Text(t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: _onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(fmtDuration(t.durationHint ?? Duration.zero),
                    style: WlText.mono(
                        fontSize: 10, color: AppTheme.textTertiary)),
                const SizedBox(width: 6),
                // hover 才显示移除按钮（避免常驻 x 干扰阅读）
                if (_hovered && !widget.isCurrent)
                  IconButton(
                    icon: const Icon(LucideIcons.x,
                        size: 14, color: AppTheme.textTertiary),
                    tooltip: l10n.queueRemove,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    splashRadius: 12,
                    onPressed: () =>
                        widget.player.removeFromQueueAt(widget.index),
                  )
                else
                  const SizedBox(width: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
