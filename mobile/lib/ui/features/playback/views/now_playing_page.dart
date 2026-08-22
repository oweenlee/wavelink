import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/song.dart';
import '../view_models/playback_controller.dart';
import '../view_models/audio_player_provider.dart';
import '../view_models/queue_provider.dart';
import '../../library/view_models/library_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/animations/app_animations.dart';
import '../../../core/widgets/progress_slider_widget.dart';
import '../../../core/widgets/album_cover.dart';
import '../../../core/widgets/queue_sheet.dart';
import '../../../core/widgets/effects_sheet.dart';
import '../../../core/widgets/lyrics_overlay.dart';

class NowPlayingPage extends ConsumerStatefulWidget {
  const NowPlayingPage({super.key});

  @override
  ConsumerState<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends ConsumerState<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  bool _lyricsOverlay = false;
  bool _lyricsBlur = false;
  late AnimationController _lyricsAc;
  late Animation<Offset> _lyricsSlide;

  @override
  void initState() {
    super.initState();
    _lyricsAc = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _lyricsSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _lyricsAc, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _lyricsAc.dispose();
    super.dispose();
  }

  void _openLyrics() {
    // 模糊淡入与上滑动画同步启动：弹出过程中由清晰渐变到模糊
    setState(() {
      _lyricsOverlay = true;
      _lyricsBlur = true;
    });
    _lyricsAc.forward();
  }

  void _closeLyrics() {
    // 下滑过程保持模糊背景，退出后再复位，避免中途变回清晰图
    _lyricsAc.reverse().then((_) {
      if (mounted) {
        setState(() {
          _lyricsBlur = false;
          _lyricsOverlay = false;
        });
      }
    });
  }

  void _openQueue(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const QueueSheet(),
    );
  }

  void _openEffects(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EffectsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    final playerState = ref.watch(playerProvider);
    final queueState = ref.watch(queueProvider);
    ref.watch(libraryProvider); // 收藏变化驱动 _Tags 重建
    final song = queueState.currentSong;

    if (song == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(
                onClose: () => Navigator.of(context).pop(),
                formatInfo: '— · no signal',
                isPlaying: false,
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        LucideIcons.music,
                        size: 80,
                        color: AppTheme.textTertiary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.nowPlayingEmpty,
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final accent = AppTheme.accentFallback;
    final fmtInfo = _buildFormatInfo(song, player);

    return AccentScope(
      accent: accent,
      child: Scaffold(
        backgroundColor: AppTheme.s0,
        body: GestureDetector(
          onVerticalDragEnd: (d) {
            if (!_lyricsOverlay &&
                d.primaryVelocity != null &&
                d.primaryVelocity! > 500) {
              HapticFeedback.lightImpact();
              Navigator.of(context).pop();
            }
          },
          child: Stack(
            children: [
              _Backdrop(coverUrl: song.coverUrl),
              SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        _TopBar(
                        onClose: () => Navigator.of(context).pop(),
                        formatInfo: fmtInfo,
                        isPlaying: playerState.isPlaying,
                        onQueue: () => _openQueue(context),
                        onEffects: () => _openEffects(context),
                        queueCount: player.queue.length,
                        song: song,
                        player: player,
                      ),
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppAnim.popIn(
                                _PauseAwareCover(
                                  isPlaying: playerState.isPlaying,
                                  child: AnimatedSwitcher(
                                    duration: AppAnim.normal,
                                    switchInCurve: AppAnim.curve,
                                    switchOutCurve: AppAnim.curveIn,
                                    child: AlbumCover(
                                      key: ValueKey('np_cover_${song.id}'),
                                      color: song.dominantColor,
                                      coverUrl: song.coverUrl,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              AppAnim.entrance(
                                _SongInfo(song: song),
                                delay: const Duration(milliseconds: 80),
                              ),
                              const SizedBox(height: 12),
                              AppAnim.entrance(
                                _Tags(player: player, song: song),
                                delay: const Duration(milliseconds: 140),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Transform.translate(
                        offset: const Offset(0, -49),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _LyricsPreview(
                              lyrics: playerState.lyrics ?? [],
                              line: playerState.currentLyricLine,
                              onTap: _openLyrics,
                            ),
                            const SizedBox(height: 4),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _ProgressRow(player: player, song: song),
                            ),
                            const SizedBox(height: 6),
                            AppAnim.entrance(
                              _TransportRow(player: player),
                              delay: const Duration(milliseconds: 200),
                              slideY: 0.15,
                            ),
                          ],
                        ),
                      ),
                      _InstrumentPanel(player: player),
                  ],
                ),
              ),
            ),
            if (_lyricsOverlay)
                SlideTransition(
                  position: _lyricsSlide,
                  child: LyricsOverlay(
                    lyrics: playerState.lyrics ?? [],
                    line: playerState.currentLyricLine,
                    onClose: _closeLyrics,
                    coverUrl: song.coverUrl,
                    positionMs: playerState.position.round(),
                    durationMs: song.duration.inMilliseconds,
                    blurred: _lyricsBlur,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmt(double ms) {
  final s = (ms / 1000).round();
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 从文件路径推断音频格式标签
String _formatFromPath(String? path) {
  if (path == null) return 'AUDIO';
  final ext = path.split('.').last.toUpperCase();
  switch (ext) {
    case 'FLAC':
      return 'FLAC';
    case 'WAV':
      return 'WAV';
    case 'DSD':
    case 'DSF':
    case 'DFF':
      return 'DSD';
    case 'MP3':
      return 'MP3';
    case 'AAC':
    case 'M4A':
      return 'AAC';
    case 'OGG':
      return 'OGG';
    case 'OPUS':
      return 'OPUS';
    case 'APE':
      return 'APE';
    case 'WV':
    case 'WAVPACK':
      return 'WAVPACK';
    case 'AIFF':
    case 'AIF':
      return 'AIFF';
    default:
      return ext;
  }
}

/// 构建顶栏格式信息字符串。
/// bit-perfect 指示基于「有效」状态（偏好 && 实际链路 && 无信号改动）：
/// - Android：仅实际 Exclusive 直通显示 bit-perfect；Shared 混音器路径如实
///   标注（Oboe 每次开流已优先试独占，设备给不给由 HAL 决定）
/// - iOS：速率匹配即 bit-exact（无独占概念，文案诚实区分，不做独占宣称）
String _buildFormatInfo(Song song, PlaybackController player) {
  final fmt = _formatFromPath(song.path);
  final t = player.telemetry;

  if (t.outputRate <= 0) return fmt; // 未播放
  if (t.fileRate <= 0) return fmt;

  if (player.effectiveBitPerfect) {
    return Platform.isAndroid
        ? '$fmt · Exclusive bit-perfect'
        : '$fmt · bit-exact（速率匹配）';
  }

  // 未达有效 bit-perfect：如实说明原因（不撒谎）
  final reasons = <String>[];
  if (!player.bitPerfect) {
    reasons.add('未开启');
  } else {
    if (t.fileRate != t.outputRate) {
      reasons.add('重采样 ${_khz(t.fileRate)}→${_khz(t.outputRate)}');
    }
    if (Platform.isAndroid && t.outputMode == 2) {
      reasons.add('Shared 混音器路径');
    }
    if (player.dspAffectingSignal) {
      reasons.add('DSP 处理中');
    }
    if (player.replayGain) {
      reasons.add('ReplayGain 增益');
    }
    if (reasons.isEmpty) reasons.add('等待播放');
  }
  return '$fmt · ${reasons.join(' / ')}';
}

/// 44100 → "44.1k"、48000 → "48k"、96000 → "96k"（顶层，供格式信息与仪表面板共用）
String _khz(int hz) {
  if (hz <= 0) return '--';
  final k = hz / 1000;
  return (hz % 1000 == 0) ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
}

// ── Instrument Panel ──

/// 仪器读数面板：输出链 / 缓冲 / 丢帧 / 引擎状态
/// 对齐 HTML prototype 2×2 网格布局
class _InstrumentPanel extends StatelessWidget {
  final PlaybackController player;
  const _InstrumentPanel({required this.player});

  @override
  Widget build(BuildContext context) {
    final t = player.telemetry;

    // Output：文件速率 → 输出速率 · direct/resample，Android 附带实际共享模式
    final String output;
    if (t.outputRate <= 0) {
      output = '-- · idle';
    } else if (t.fileRate > 0) {
      final mode = Platform.isAndroid
          ? (t.outputMode == 1
                ? ' · Exclusive'
                : (t.outputMode == 2 ? ' · Shared' : ''))
          : ''; // iOS 无独占概念
      output =
          '${_khz(t.fileRate)} → ${_khz(t.outputRate)} · ${t.bitPerfect ? 'direct' : 'resample'}$mode';
    } else {
      output = '${_khz(t.outputRate)} · --';
    }

    final underrun = 'Total ${t.underrunTotal} · ${t.underrunRecent} recent';
    final buffer = '${t.bufferMs}ms · ${t.bufferStarving ? 'starving' : 'ok'}';
    final engineState = t.running ? 'running' : (player.hasSong ? 'paused' : 'idle');
    final engine = '$engineState · FFT 1024';

    return Container(
      margin: const EdgeInsets.only(top: 12, left: 14, right: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.s1.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.divider, width: 0.5),
      ),
      // 双行仪表条 + 横向滚动：两行同步滑动列对齐，内容永不裁切
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _InstChip(label: 'OUTPUT', value: output),
                const _ChipGap(),
                _InstChip(label: 'UNDERRUN', value: underrun),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _InstChip(label: 'BUFFER', value: buffer),
                const _ChipGap(),
                _InstChip(label: 'ENGINE', value: engine),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 仪表条分隔符
class _ChipGap extends StatelessWidget {
  const _ChipGap();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        width: 1,
        height: 12,
        color: AppTheme.divider,
      ),
    );
  }
}

/// 仪表条单项：小标签 + 值，单行不截断
class _InstChip extends StatelessWidget {
  final String label;
  final String value;
  const _InstChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: WlText.mono(
            fontSize: 8,
            color: AppTheme.textTertiary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          maxLines: 1,
          style: WlText.mono(
            fontSize: 10,
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── Top Bar ──

class _TopBar extends StatelessWidget {
  final VoidCallback onClose;
  final String formatInfo;
  final bool isPlaying;
  final VoidCallback? onQueue;
  final VoidCallback? onEffects;
  final int queueCount;
  final Song? song;
  final PlaybackController? player;
  const _TopBar({
    required this.onClose,
    required this.formatInfo,
    required this.isPlaying,
    this.onQueue,
    this.onEffects,
    this.queueCount = 0,
    this.song,
    this.player,
  });

  @override
  Widget build(BuildContext context) {
    final hasMenu = onQueue != null || onEffects != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              LucideIcons.chevronDown,
              color: AppTheme.textPrimary,
            ),
            onPressed: onClose,
            splashRadius: 20,
          ),
          const Spacer(),
          Text(
            formatInfo,
            style: WlText.mono(fontSize: 10, color: AppTheme.textSecondary),
          ),
          const SizedBox(width: 8),
          _EngineLed(isPlaying: isPlaying),
          const Spacer(),
          if (hasMenu)
            Builder(
              builder: (btnContext) => IconButton(
                icon: const Icon(
                  LucideIcons.moreHorizontal,
                  color: AppTheme.textPrimary,
                ),
                onPressed: () => _openMoreMenu(
                  btnContext,
                  queueCount: queueCount,
                  onQueue: onQueue,
                  onEffects: onEffects,
                ),
                splashRadius: 20,
              ),
            )
          else
            IconButton(
              icon: const Icon(
                LucideIcons.moreHorizontal,
                color: AppTheme.textPrimary,
              ),
              onPressed: () {},
              splashRadius: 20,
            ),
        ],
      ),
    );
  }
}

/// 引擎状态 LED：播放时绿色脉冲，暂停时琥珀色常亮
class _EngineLed extends StatefulWidget {
  final bool isPlaying;
  const _EngineLed({required this.isPlaying});
  @override
  State<_EngineLed> createState() => _EngineLedState();
}

class _EngineLedState extends State<_EngineLed>
    with SingleTickerProviderStateMixin {
  late AnimationController _ac;
  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.isPlaying) _ac.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _EngineLed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !oldWidget.isPlaying) {
      _ac.repeat(reverse: true);
    } else if (!widget.isPlaying && oldWidget.isPlaying) {
      _ac.stop();
      _ac.value = 0;
    }
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paused = !widget.isPlaying;
    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) {
        final baseColor = paused ? AppTheme.warn : AppTheme.ok;
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: paused
                ? baseColor
                : baseColor.withValues(alpha: 0.6 + _ac.value * 0.4),
            boxShadow: [
              BoxShadow(
                color: baseColor.withValues(alpha: paused ? 0.5 : 0.3),
                blurRadius: paused ? 4 : 4,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Pause-Aware Cover ──

/// 暂停时封面缩小至 0.92 + 降低亮度/饱和度（对齐 HTML 原型 .paused 规则）
class _PauseAwareCover extends StatelessWidget {
  final bool isPlaying;
  final Widget child;

  const _PauseAwareCover({required this.isPlaying, required this.child});

  /// b=0.65, s=0.6 组合矩阵
  static const _pauseMatrix = <double>[
    0.445, 0.186, 0.019, 0, 0, //
    0.055, 0.576, 0.019, 0, 0,
    0.055, 0.186, 0.409, 0, 0,
    0, 0, 0, 1, 0,
  ];

  @override
  Widget build(BuildContext context) {
    Widget result = child;
    if (!isPlaying) {
      result = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_pauseMatrix),
        child: result,
      );
    }
    return AnimatedScale(
      scale: isPlaying ? 1.0 : 0.92,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      child: result,
    );
  }
}

// ── Song Info ──

class _SongInfo extends StatelessWidget {
  final Song song;
    const _SongInfo({required this.song});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          song.title,
          style: WlText.display(fontSize: 24, fontWeight: FontWeight.w600),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          '${song.artist} · ${song.album}',
          style: const TextStyle(
            fontSize: 15,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

// ── Tags ──

class _Tags extends StatelessWidget {
  final PlaybackController player;
  final Song song;
  const _Tags({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    final analysis = player.getAnalysis(song.id);
    final bpm = analysis?.bpm;
    final key = analysis?.key;
    return Wrap(
      spacing: 8,
      children: [
          // key 带 song.id：切歌后倍速选择随新歌重置，不残留上一首的状态
          if (bpm != null)
            _BpmTag(
              key: ValueKey('bpm_${song.id}'),
              bpm: bpm,
              confidence: analysis?.bpmConfidence,
            ),
          if (key != null)
            _TechTag(
              icon: LucideIcons.music,
              label: key,
              confidence: analysis?.keyConfidence,
            ),
        ],
    );
  }
}

/// BPM 标签：点击循环切换 ×1 → ÷2 → ×2（结果限 60-200 内）。
/// 检测值存在固有 ×2/÷2 歧义（慢歌八分音符网格≈140，感知拍可能是 70），
/// 算法无法自动消解；与 DJ 软件（rekordbox/Serato）同款交互：一键切到感知拍。
class _BpmTag extends StatefulWidget {
  final double bpm;
  final double? confidence;
  const _BpmTag({super.key, required this.bpm, this.confidence});

  @override
  State<_BpmTag> createState() => _BpmTagState();
}

class _BpmTagState extends State<_BpmTag> {
  static const _scales = [1.0, 0.5, 2.0];
  int _scaleIdx = 0;

  @override
  Widget build(BuildContext context) {
    final scale = _scales[_scaleIdx];
    final scaled = widget.bpm * scale;
    final suffix = scale == 1.0
        ? ''
        : scale < 1.0
        ? ' /2'
        : ' ×2';
    return Tooltip(
      message: '点击切换半速/倍速（检测值可能有 ×2/÷2 歧义）',
      child: GestureDetector(
        onTap: () {
          setState(() {
            for (var i = 1; i <= _scales.length; i++) {
              final idx = (_scaleIdx + i) % _scales.length;
              final v = widget.bpm * _scales[idx];
              if (v >= 60 && v <= 200) {
                _scaleIdx = idx;
                break;
              }
            }
          });
        },
        child: _TechTag(
          icon: LucideIcons.gauge,
          label: '${scaled.round()} BPM$suffix',
          confidence: widget.confidence,
        ),
      ),
    );
  }
}

class _TechTag extends StatelessWidget {
  final IconData icon;
  final String label;
  final double? confidence;
  const _TechTag({required this.icon, required this.label, this.confidence});

  @override
  Widget build(BuildContext context) {
    // 与前进/后退同色（textSecondary）：标签不再跟随封面主色
    const c = AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.2), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: WlText.mono(
              fontSize: 11,
              color: c,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (confidence != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: '置信度 ${(confidence! * 100).round()}%',
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _confColor(confidence!),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 置信度（0~1）→ 状态点颜色：高=绿，中=琥珀，低=红。
Color _confColor(double conf) {
  if (conf >= 0.6) return const Color(0xFF34D399);
  if (conf >= 0.35) return const Color(0xFFFBBF24);
  return const Color(0xFFF87171);
}

// ── Progress Row ──

class _ProgressRow extends StatelessWidget {
  final PlaybackController player;
  final Song song;
  const _ProgressRow({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    return ProgressSliderWidget(
      progress: player.progress,
      current: _fmt(player.position),
      total: song.formattedDuration,
      onChanged: (v) => player.seek(v),
      onDragStart: (_) => player.setDragging(true),
      onChangeEnd: (v) {
        player.setDragging(false);
        player.seek(v, immediate: true);
      },
    );
  }
}

// ── Transport ──

class _TransportRow extends StatelessWidget {
  final PlaybackController player;
  const _TransportRow({required this.player});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _ModeBtn(
            loopMode: player.loopMode,
            onTap: () => player.toggleLoopMode(),
          ),
          _TransportBtn(
            icon: Icons.skip_previous,
            size: 44,
            filled: true,
            onTap: () => player.previous(fromUser: true),
          ),
          _PlayBtn(
            isPlaying: player.isPlaying,
            onTap: () => player.togglePlay(),
          ),
          _TransportBtn(
            icon: Icons.skip_next,
            size: 44,
            filled: true,
            onTap: () => player.next(fromUser: true),
          ),
          _TransportBtn(
            icon: player.isFavorite ? Icons.favorite : Icons.favorite_border,
            size: 44,
            filled: true,
            active: player.isFavorite,
            activeColor: AppTheme.danger,
            onTap: () {
              HapticFeedback.lightImpact();
              player.toggleFavorite();
            },
          ),
        ],
      ),
    );
  }
}

class _ModeBtn extends StatelessWidget {
  final LoopMode loopMode;
  final VoidCallback onTap;

  const _ModeBtn({required this.loopMode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // 与前进/后退完全同风格：同色（textSecondary）、无填充；
    // 循环/单曲/随机的状态由图标本身表达
    const color = AppTheme.textSecondary;

    IconData icon;
    switch (loopMode) {
      case LoopMode.single:
        icon = LucideIcons.repeat1;
      case LoopMode.shuffle:
        icon = LucideIcons.shuffle;
      case LoopMode.list:
        icon = LucideIcons.repeat;
    }

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(child: Icon(icon, color: color, size: 20)),
      ),
    );
  }
}

class _TransportBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final bool filled;
  const _TransportBtn({
    required this.icon,
    this.size = 36,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final color = active
        ? (activeColor ?? accent)
        : AppTheme.textSecondary;
    // Material Icons (filled) are naturally larger, scale down a bit
    final iconSize = filled ? size * 0.5 : size * 0.6;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: Center(child: Icon(icon, color: color, size: iconSize)),
      ),
    );
  }
}

class _PlayBtn extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onTap;
  const _PlayBtn({required this.isPlaying, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // 点击播放/暂停：轻震动反馈
        HapticFeedback.lightImpact();
        onTap();
      },
      // 与前进/后退同风格：同色（textSecondary）、无填充，
      // 主次仅靠尺寸（60px）区分
      child: SizedBox(
        width: 60,
        height: 60,
        // 播放/暂停图标 scale+fade 过渡
        child: Center(
          child: AnimatedSwitcher(
            duration: AppAnim.fast,
            switchInCurve: AppAnim.curve,
            switchOutCurve: AppAnim.curveIn,
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Icon(
              key: ValueKey('np_play_$isPlaying'),
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: AppTheme.textSecondary,
              size: 32,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Lyrics Preview (1 line) ──

class _LyricsPreview extends StatelessWidget {
  final List<LyricLine> lyrics;
  final int line;
  final VoidCallback onTap;
  const _LyricsPreview({
    required this.lyrics,
    required this.line,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasLyrics = lyrics.isNotEmpty && line >= 0 && line < lyrics.length;
    if (!hasLyrics) return const SizedBox(height: 64);

    // 三行：前一行 / 当前行 / 后一行
    final lines = <String>[];
    int currentIdx = 0;
    if (line > 0) {
      lines.add(lyrics[line - 1].text);
      currentIdx = 1;
    }
    lines.add(lyrics[line].text);
    if (line < lyrics.length - 1) lines.add(lyrics[line + 1].text);
    while (lines.length < 3) {
      lines.add('');
    }

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(lines.length, (i) {
            final isCurrent = i == currentIdx;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                lines[i],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  color: isCurrent
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ── Blurred Cover Backdrop ──

/// 模糊封面底色 — 对齐 HTML prototype `#backdrop`
class _Backdrop extends ConsumerWidget {
  final String? coverUrl;
  const _Backdrop({required this.coverUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 模糊强度偏好（0–1，默认 0.7）映射到 sigma 0–40；0 = 不模糊。
    // 直接 watch playerProvider 的 select：设置页拖动滑块时实时重建本视图
    //（原来 watch 的是永不通知的 playbackControllerProvider，更新依赖
    // 父级被 position tick 带着重建的巧合，暂停时会冻结在旧值）。
    final sigma = ref.watch(playerProvider.select((s) => s.coverBlur)) * 40;
    return RepaintBoundary(
      child: Stack(
        children: [
          // 模糊封面（coverUrl 为本地缓存文件；异步就绪后 fade-in，切歌不闪变）
          if (coverUrl != null && coverUrl!.isNotEmpty)
            Positioned.fill(
              child: Image.file(
                File(coverUrl!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, _) =>
                    frame == null ? _fallbackGradient() : child,
                errorBuilder: (_, e, s) => _fallbackGradient(),
              ),
            )
          else
            _fallbackGradient(),
          // 模糊层（静态背景用 RepaintBoundary 隔离，避免上层动画触发整屏重模糊）
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.fromRGBO(8, 9, 10, 0.55),
                      Color.fromRGBO(8, 9, 10, 0.3),
                      Color.fromRGBO(8, 9, 10, 0.7),
                      Color.fromRGBO(8, 9, 10, 0.95),
                    ],
                    stops: [0.0, 0.4, 0.8, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackGradient() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.s2, AppTheme.s1, AppTheme.background],
          stops: [0.0, 0.3, 1.0],
        ),
      ),
    );
  }
}

/// 播放页 ⋮ 菜单：底部操作表。含播放层（队列/音效）与当前歌曲操作
/// （播放下一首/加入队列/添加到播放列表/收藏），对齐主流 App（Spotify/
/// Apple Music）在播放页提供队列与歌单管理入口的做法。
Future<void> _openMoreMenu(
  BuildContext context, {
  int queueCount = 0,
  VoidCallback? onQueue,
  VoidCallback? onEffects,
}) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          color: AppTheme.surfaceDark,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // —— 播放层 ——
            if (onQueue != null)
              _ArrowMenuItem(
                icon: LucideIcons.listMusic,
                label: l10n.queue,
                trailing: queueCount > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.textTertiary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$queueCount',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onQueue();
                },
              ),
            if (onEffects != null)
              _ArrowMenuItem(
                icon: LucideIcons.slidersHorizontal,
                label: l10n.sound,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onEffects();
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// 播放页「添加到播放列表」已随菜单精简移除：添加歌单入口保留在曲库菜单。

/// 菜单单项：图标 + 文字 + 可选尾部徽标
class _ArrowMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;
  const _ArrowMenuItem({
    required this.icon,
    required this.label,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppTheme.textPrimary),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
            ),
            if (trailing != null) ...[
              const Spacer(),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
