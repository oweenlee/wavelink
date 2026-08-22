import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_anim.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/lyrics.dart';
import '../services/player_notifier.dart';
import '../services/player_providers.dart';
import '../widgets/cover_art.dart';
import '../widgets/wl_slider.dart';
import '../widgets/spectrum_visualizer.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

/// 右侧「正在播放」面板（对齐 mobile 播放页的信息密度布局，
/// 桌面形态为常驻侧栏）：封面 + 标题/艺术家 + 分析徽章 + 频谱 +
/// 进度条 + 歌词滚动。
class NowPlaying extends ConsumerWidget {
  final PlayerNotifier player;
  final double width;
  const NowPlaying({super.key, required this.player, this.width = 320});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch currentTrack：切歌 / 封面异步提取写回 state 后面板都能刷新
    final track = ref.watch(playerProvider.select((s) => s.currentTrack));
    final l10n = AppLocalizations.of(context);
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(left: BorderSide(color: _border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: CoverArt(
                key: ValueKey('np-${track?.coverUrl ?? track?.id ?? 'empty'}'),
                seed: track?.id ?? 'empty',
                coverUrl: track?.coverUrl,
                size: 168,
                rounded: true,
              ),
            ),
            const SizedBox(height: 16),
            Text(track?.title ?? l10n.nowPlayingEmpty,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: WlText.display(fontSize: 17)),
            const SizedBox(height: 4),
            Text(track?.artist ?? l10n.tapToStart,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 10),
            // BPM/Key 分析徽章（播放时后台分析，完成后经 analysisStream 刷新）
            RepaintBoundary(
              child: StreamBuilder<String>(
                stream: player.analysisStream,
                builder: (context, _) =>
                    _AnalysisTags(player: player, track: track),
              ),
            ),
            const SizedBox(height: 14),
            // 实时频谱（引擎 spectrum 事件驱动；暂停后自然衰减到零）
            RepaintBoundary(child: SpectrumVisualizer(player: player, height: 36)),
            const SizedBox(height: 12),
            RepaintBoundary(child: _Progress(player: player)),
            const SizedBox(height: 12),
            RepaintBoundary(child: Expanded(child: _Lyrics(player: player))),
          ],
        ),
      ),
    );
  }
}

/// BPM / Key 分析徽章（对齐 mobile 播放页 _Tags）。无结果（未分析完/失败）
/// 时渲染为空，不占位；分析完成经 [PlayerNotifier.analysisStream] 触发重建。
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
            Text(fmtDuration(dur), style: const TextStyle(color: _onSurfaceVariant, fontSize: 12)),
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
          );
        },
      ),
    );
  }
}
