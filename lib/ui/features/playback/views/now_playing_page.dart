import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/song.dart';
import '../view_models/playback_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/progress_slider_widget.dart';
import '../../../core/widgets/album_cover.dart';
import '../../../core/widgets/lyrics_overlay.dart';
import '../../../core/widgets/queue_sheet.dart';
import '../../../core/widgets/effects_sheet.dart';

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  bool _lyricsOverlay = false;
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
    setState(() => _lyricsOverlay = true);
    _lyricsAc.forward();
  }

  void _closeLyrics() {
    _lyricsAc.reverse().then((_) {
      if (mounted) setState(() => _lyricsOverlay = false);
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
    final player = context.watch<PlaybackProvider>();
    final song = player.currentSong;

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
    final fmtInfo = _buildFormatInfo(song, player.bitPerfect);

    return AccentScope(
      accent: accent,
      child: Scaffold(
        backgroundColor: AppTheme.s0,
        body: GestureDetector(
          onVerticalDragEnd: (d) {
            if (!_lyricsOverlay &&
                d.primaryVelocity != null &&
                d.primaryVelocity! > 500) {
              Navigator.of(context).pop();
            }
          },
          child: Stack(
            children: [
              // 模糊封面底色 — 对齐 HTML prototype 的 blurred backdrop
              _Backdrop(coverUrl: song.coverUrl),
              SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        _TopBar(
                        onClose: () => Navigator.of(context).pop(),
                        formatInfo: fmtInfo,
                        isPlaying: player.isPlaying,
                      ),
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _PauseAwareCover(
                                isPlaying: player.isPlaying,
                                child: AlbumCover(
                                  color: song.dominantColor,
                                  coverUrl: song.coverUrl,
                                ),
                              ),
                              const SizedBox(height: 20),
                              _SongInfo(song: song),
                              const SizedBox(height: 12),
                              _Tags(player: player, song: song),
                              const SizedBox(height: 16),
                              _Spectrum(isPlaying: player.isPlaying),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _ProgressRow(player: player, song: song),
                      ),
                      const SizedBox(height: 4),
                      _TransportRow(player: player),
                      const SizedBox(height: 18),
                      _BottomToolbar(
                        player: player,
                        lyricsActive: _lyricsOverlay,
                        onQueue: () => _openQueue(context),
                        onEffects: () => _openEffects(context),
                        onLyrics: _openLyrics,
                      ),
                      const SizedBox(height: 4),
                      _LyricsPreview(
                        lyrics: player.currentLyrics ?? [],
                        line: player.currentLyricLine,
                        onTap: _openLyrics,
                      ),
                      _InstrumentPanel(player: player),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              if (_lyricsOverlay)
                SlideTransition(
                  position: _lyricsSlide,
                  child: LyricsOverlay(
                    lyrics: player.currentLyrics ?? [],
                    line: player.currentLyricLine,
                    onClose: _closeLyrics,
                    coverUrl: song.coverUrl,
                    positionMs: player.position.round(),
                    durationMs: song.duration.inMilliseconds,
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

/// 构建顶栏格式信息字符串
/// TODO: 接入 Rust 引擎获取真实采样率/位深
String _buildFormatInfo(Song song, bool bitPerfect) {
  final fmt = _formatFromPath(song.path);
  return '$fmt${bitPerfect ? ' · bit-perfect' : ''}';
}

// ── Instrument Panel ──

/// 仪器读数面板：输出链 / 缓冲 / 丢帧 / 引擎状态
/// 对齐 HTML prototype 2×2 网格布局
class _InstrumentPanel extends StatelessWidget {
  final PlaybackProvider player;
  const _InstrumentPanel({required this.player});

  /// 44100 → "44.1k"、48000 → "48k"、96000 → "96k"
  static String _khz(int hz) {
    if (hz <= 0) return '--';
    final k = hz / 1000;
    return (hz % 1000 == 0) ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }

  @override
  Widget build(BuildContext context) {
    final t = player.telemetry;

    // Output：文件速率 → 输出速率 · direct/resample
    final String output;
    if (t.outputRate <= 0) {
      output = '-- · idle';
    } else if (t.fileRate > 0) {
      output =
          '${_khz(t.fileRate)} → ${_khz(t.outputRate)} · ${t.bitPerfect ? 'direct' : 'resample'}';
    } else {
      output = '${_khz(t.outputRate)} · --';
    }

    final underrun = 'Total ${t.underrunTotal} · ${t.underrunRecent} recent';
    final buffer = '${t.bufferMs}ms · ${t.bufferStarving ? 'starving' : 'ok'}';
    final engine = '${t.running ? 'running' : 'idle'} · FFT 1024';

    return Container(
      margin: const EdgeInsets.only(top: 18, left: 14, right: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.s1.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.divider, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InstGridRow(label: 'Output', value: output),
                const SizedBox(height: 6),
                _InstGridRow(label: 'Underrun', value: underrun),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InstGridRow(label: 'Buffer', value: buffer),
                const SizedBox(height: 6),
                _InstGridRow(label: 'Engine', value: engine),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InstGridRow extends StatelessWidget {
  final String label;
  final String value;
  const _InstGridRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: WlText.mono(
            fontSize: 9,
            color: AppTheme.textTertiary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: WlText.mono(
              fontSize: 10,
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w500,
            ),
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
  const _TopBar({
    required this.onClose,
    required this.formatInfo,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
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
          style: WlText.display(fontSize: 26, fontWeight: FontWeight.w600),
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
  final PlaybackProvider player;
  final Song song;
  const _Tags({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final analysis = player.getAnalysis(song.id);
    final bpm = analysis?.bpm;
    final key = analysis?.key;
    return Wrap(
      spacing: 8,
      children: [
          if (bpm != null)
            _TechTag(icon: LucideIcons.gauge, label: '${bpm.round()} BPM'),
          if (key != null)
            _TechTag(icon: LucideIcons.music, label: key),
          if (player.isSongFavorite(song.id))
            _TechTag(
              icon: LucideIcons.heart,
              label: l10n.favorited,
              accent: AppTheme.danger,
            ),
        ],
    );
  }
}

class _TechTag extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? accent;
  const _TechTag({required this.icon, required this.label, this.accent});

  @override
  Widget build(BuildContext context) {
    final c = accent ?? AccentScope.of(context);
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
        ],
      ),
    );
  }
}

// ── Progress Row ──

class _ProgressRow extends StatelessWidget {
  final PlaybackProvider player;
  final Song song;
  const _ProgressRow({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    return ProgressSliderWidget(
      progress: player.progress,
      current: _fmt(player.position),
      total: song.formattedDuration,
      onChanged: (v) => player.seek(v),
      onChangeEnd: (v) => player.seek(v, immediate: true),
    );
  }
}

// ── Transport ──

class _TransportRow extends StatelessWidget {
  final PlaybackProvider player;
  const _TransportRow({required this.player});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 模式按钮 — 单独左侧
          Positioned(
            left: 0,
            top: 12,
            child: _ModeBtn(
              loopMode: player.loopMode,
              onTap: () => player.toggleLoopMode(),
            ),
          ),
          // prev-play-next 组 — 死中心
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TransportBtn(
                icon: Icons.skip_previous,
                size: 44,
                filled: true,
                onTap: () => player.previous(),
              ),
              const SizedBox(width: 32),
              _PlayBtn(
                isPlaying: player.isPlaying,
                onTap: () => player.togglePlay(),
              ),
              const SizedBox(width: 32),
              _TransportBtn(
                icon: Icons.skip_next,
                size: 44,
                filled: true,
                onTap: () => player.next(),
              ),
            ],
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
    final accent = AccentScope.of(context);
    final active = loopMode != LoopMode.list;
    final color = active ? accent : AppTheme.textSecondary;

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
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(shape: BoxShape.circle),
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
  final bool filled;
  const _TransportBtn({
    required this.icon,
    this.size = 36,
    required this.onTap,
    this.active = false,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final color = active ? accent : AppTheme.textSecondary;
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
    final accent = AccentScope.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: accent,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 14),
          ],
        ),
        child: Icon(
          isPlaying ? Icons.pause : Icons.play_arrow,
          color: Colors.white,
          size: 30,
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
    if (!hasLyrics) return const SizedBox.shrink();

    final text = lyrics[line].text;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            Icon(LucideIcons.text, size: 16, color: AppTheme.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              LucideIcons.chevronUp,
              size: 16,
              color: AppTheme.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bottom Toolbar ──

class _BottomToolbar extends StatelessWidget {
  final PlaybackProvider player;
  final bool lyricsActive;
  final VoidCallback onQueue;
  final VoidCallback onEffects;
  final VoidCallback onLyrics;
  const _BottomToolbar({
    required this.player,
    required this.lyricsActive,
    required this.onQueue,
    required this.onEffects,
    required this.onLyrics,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _BarItem(
            icon: LucideIcons.heart,
            label: l10n.favorite,
            active: player.isFavorite,
            activeColor: AppTheme.danger,
            onTap: () => player.toggleFavorite(),
          ),
          _BarItem(
            icon: LucideIcons.text,
            label: l10n.lyrics,
            active: lyricsActive,
            onTap: onLyrics,
          ),
          _BarItem(
            icon: LucideIcons.slidersHorizontal,
            label: l10n.sound,
            onTap: onEffects,
          ),
          _BarItem(
            icon: LucideIcons.listMusic,
            label: l10n.queue,
            onTap: onQueue,
            badge: '${player.queue.length}',
          ),
        ],
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;
  final String? badge;
  const _BarItem({
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final color = active ? (activeColor ?? accent) : AppTheme.textTertiary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, color: color, size: 20),
              if (badge != null)
                Positioned(
                  right: -10,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.04,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Blurred Cover Backdrop ──

/// 模糊封面底色 — 对齐 HTML prototype `#backdrop`
class _Backdrop extends StatelessWidget {
  final String? coverUrl;
  const _Backdrop({required this.coverUrl});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 模糊封面
        if (coverUrl != null && coverUrl!.isNotEmpty)
          Positioned.fill(
            child: Image.network(
              coverUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, e, s) => _fallbackGradient(),
            ),
          )
        else
          _fallbackGradient(),
        // 模糊层
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
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

// ── Spectrum Visualizer ──

/// 48 条频谱可视化器 — 对齐 HTML prototype `.spectrum`
class _Spectrum extends StatefulWidget {
  final bool isPlaying;
  const _Spectrum({required this.isPlaying});

  @override
  State<_Spectrum> createState() => _SpectrumState();
}

class _SpectrumState extends State<_Spectrum>
    with SingleTickerProviderStateMixin {
  final _rng = Random();
  final _heights = List.filled(48, 2.0);
  late AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    )..addListener(_tick);
    if (widget.isPlaying) _ac.repeat();
  }

  @override
  void didUpdateWidget(covariant _Spectrum oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !oldWidget.isPlaying) {
      _ac.repeat();
    } else if (!widget.isPlaying && oldWidget.isPlaying) {
      _ac.stop();
    }
  }

  void _tick() {
    for (int i = 0; i < 48; i++) {
      final shape = pow(1 - i / 48, 0.5).toDouble();
      _heights[i] = widget.isPlaying
          ? (shape * 24 + _rng.nextDouble() * 4).clamp(2.0, 28.0)
          : 2.0;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          children: List.generate(48, (i) {
            return Expanded(
              child: Container(
                width: 1.5,
                height: _heights[i],
                decoration: BoxDecoration(
                  color: accent
                      .withValues(alpha: widget.isPlaying ? 0.85 : 0.2),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
