import 'package:flutter/material.dart';
import 'package:wavelink_mobile/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../models/lyric_line.dart';
import '../models/song.dart';
import '../providers/playback_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/progress_slider_widget.dart';
import '../widgets/spectrum_bar.dart';

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
    final p = ctx.read<PlaybackProvider>();
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QueueSheet(player: p),
    );
  }

  void _openEffects(BuildContext ctx) {
    final p = ctx.read<PlaybackProvider>();
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EffectsSheet(player: p),
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
              _TopBar(onClose: () => Navigator.of(context).pop()),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.music_note_outlined,
                        size: 80,
                        color: AppTheme.textTertiary,
                      ),
                      SizedBox(height: 16),
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

    final bg = song.dominantColor;

    return Scaffold(
      backgroundColor: bg.withValues(alpha: 0.95),
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
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bg, bg.withValues(alpha: 0.5), AppTheme.background],
                  stops: const [0.0, 0.3, 1.0],
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    _TopBar(onClose: () => Navigator.of(context).pop()),
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _AlbumCover(color: song.dominantColor),
                            const SizedBox(height: 20),
                            _SongInfo(song: song),
                            const SizedBox(height: 12),
                            _Tags(player: player, song: song),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _ProgressRow(player: player, song: song),
                    ),
                    const SizedBox(height: 4),
                    _TransportRow(player: player),
                    const SizedBox(height: 12),
                    _LyricsPreview(
                      lyrics: player.currentLyrics ?? [],
                      line: player.currentLyricLine,
                      onTap: _openLyrics,
                    ),
                    const SizedBox(height: 12),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: SpectrumBar(),
                    ),
                    const SizedBox(height: 8),
                    _BottomToolbar(
                      player: player,
                      lyricsActive: _lyricsOverlay,
                      onQueue: () => _openQueue(context),
                      onEffects: () => _openEffects(context),
                      onLyrics: _openLyrics,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            if (_lyricsOverlay)
              SlideTransition(
                position: _lyricsSlide,
                child: _LyricsOverlay(
                  lyrics: player.currentLyrics ?? [],
                  line: player.currentLyricLine,
                  dominantColor: song.dominantColor,
                  onClose: _closeLyrics,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _fmt(double ms) {
  final s = (ms / 1000).round();
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

// ── Top Bar ──

class _TopBar extends StatelessWidget {
  final VoidCallback onClose;
  const _TopBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: AppTheme.textPrimary,
            ),
            onPressed: onClose,
            splashRadius: 20,
          ),
          const Spacer(),
          Text(
            l10n.currentPlaying,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppTheme.textPrimary.withValues(alpha: 0.8),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(
              Icons.more_horiz_rounded,
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

// ── Song Info ──

class _SongInfo extends StatelessWidget {
  final Song song;
  const _SongInfo({required this.song});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            song.title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            '${song.artist} · ${song.album}',
            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
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
      alignment: WrapAlignment.center,
      children: [
        if (bpm != null)
          _Tag(icon: Icons.speed_rounded, label: '${bpm.round()} BPM'),
        if (key != null)
          _Tag(icon: Icons.music_note_rounded, label: key),
        if (player.isSongFavorite(song.id))
          _Tag(icon: Icons.favorite_rounded, label: l10n.favorited),
      ],
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _AuxBtn(
          icon: Icons.fast_rewind_rounded,
          onTap: () => player.skipBackward(),
        ),
        const SizedBox(width: 12),
        _AuxBtn(
          icon: Icons.skip_previous_rounded,
          size: 44,
          onTap: () => player.previous(),
        ),
        const SizedBox(width: 16),
        _PlayBtn(isPlaying: player.isPlaying, onTap: () => player.togglePlay()),
        const SizedBox(width: 16),
        _AuxBtn(
          icon: Icons.skip_next_rounded,
          size: 44,
          onTap: () => player.next(),
        ),
        const SizedBox(width: 12),
        _AuxBtn(
          icon: Icons.fast_forward_rounded,
          onTap: () => player.skipForward(),
        ),
      ],
    );
  }
}

class _AuxBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  const _AuxBtn({required this.icon, this.size = 36, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: Icon(icon, color: AppTheme.textPrimary, size: size * 0.6),
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
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: AppTheme.accentBlue,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppTheme.accentBlue.withValues(alpha: 0.3),
              blurRadius: 12,
            ),
          ],
        ),
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
    final l10n = AppLocalizations.of(context);
    final hasLyrics = lyrics.isNotEmpty && line >= 0 && line < lyrics.length;
    final text = hasLyrics ? lyrics[line].text : l10n.noLyrics;

    return GestureDetector(
      onTap: hasLyrics ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.lyrics_rounded, size: 16, color: AppTheme.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary.withValues(
                    alpha: hasLyrics ? 0.8 : 0.35,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasLyrics)
              Icon(
                Icons.keyboard_arrow_up_rounded,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BarItem(
            icon: Icons.queue_music_rounded,
            label: l10n.queue,
            onTap: onQueue,
            badge: '${player.queue.length}',
          ),
          _BarItem(icon: Icons.tune_rounded, label: l10n.sound, onTap: onEffects),
          _BarItem(
            icon: lyricsActive ? Icons.lyrics_rounded : Icons.lyrics_outlined,
            label: l10n.lyrics,
            active: lyricsActive,
            onTap: onLyrics,
          ),
          _BarItem(
            icon: player.isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: l10n.favorite,
            active: player.isFavorite,
            activeColor: AppTheme.danger,
            onTap: () => player.toggleFavorite(),
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
    final color = active
        ? (activeColor ?? AppTheme.accentBlue)
        : AppTheme.textSecondary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: color, size: 22),
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
                        color: AppTheme.accentBlue,
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
                fontSize: 10,
                color: color.withValues(alpha: active ? 1.0 : 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Bottom Sheets
// ═══════════════════════════════════════════════════════════════

// ── Queue Sheet ──

class _QueueSheet extends StatelessWidget {
  final PlaybackProvider player;
  const _QueueSheet({required this.player});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _SheetShell(
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
                  Icons.delete_outline_rounded,
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
                      Icons.drag_handle_rounded,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: s.dominantColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: isCurrent
                          ? const Center(child: _NowPlayingIndicator())
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
                                  ? AppTheme.accentBlue
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
                          Icons.close_rounded,
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

// ── Effects Sheet ──

class _EffectsSheet extends StatelessWidget {
  final PlaybackProvider player;
  const _EffectsSheet({required this.player});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dsp = player.dspSettings;
    return _SheetShell(
      title: l10n.soundSettings,
      builder: (scroll) {
        return ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
            _EffectItem(
              icon: Icons.tune_rounded,
              label: l10n.eq10Band,
              subtitle: dsp.enabled ? l10n.enabled : l10n.disabled,
              trailing: _Toggle(
                value: dsp.enabled,
                onChanged: player.toggleDspEnabled,
              ),
            ),
            const _Divider(),
            _EffectItem(
              icon: Icons.vibration_rounded,
              label: l10n.bauerCrossfeed,
              subtitle: dsp.crossfeed ? l10n.enabled : l10n.bauerCrossfeed,
              trailing: _Toggle(
                value: dsp.crossfeed,
                onChanged: player.toggleCrossfeed,
              ),
            ),
            const _Divider(),
            _EffectItem(
              icon: Icons.arrow_right_alt_rounded,
              label: l10n.stereoWidening,
              subtitle: dsp.widener ? l10n.enabled : l10n.stereoWidening,
              trailing: _Toggle(
                value: dsp.widener,
                onChanged: player.toggleWidener,
              ),
            ),
            const _Divider(),
            _EffectItem(
              icon: Icons.volume_up_rounded,
              label: l10n.truePeakLimiter,
              subtitle: dsp.limiter ? l10n.enabled : l10n.truePeakLimiter,
              trailing: _Toggle(
                value: dsp.limiter,
                onChanged: player.toggleLimiter,
              ),
            ),
            const _Divider(),
            _EffectItem(
              icon: Icons.graphic_eq_rounded,
              label: l10n.tpdfDither,
              subtitle: dsp.dither ? l10n.enabled : l10n.tpdfDither,
              trailing: _Toggle(
                value: dsp.dither,
                onChanged: player.toggleDither,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Lyrics Overlay (full screen) ──

class _LyricsOverlay extends StatefulWidget {
  final List<LyricLine> lyrics;
  final int line;
  final Color dominantColor;
  final VoidCallback onClose;
  const _LyricsOverlay({
    required this.lyrics,
    required this.line,
    required this.dominantColor,
    required this.onClose,
  });

  @override
  State<_LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends State<_LyricsOverlay> {
  final _scroll = ScrollController();
  int _prev = -1;

  @override
  void didUpdateWidget(_LyricsOverlay old) {
    super.didUpdateWidget(old);
    if (widget.line != _prev && widget.line >= 0 && widget.lyrics.isNotEmpty) {
      _prev = widget.line;
      _scrollToCurrent();
    }
  }

  void _scrollToCurrent() {
    if (_scroll.hasClients) {
      final offset =
          widget.line * 56.0 - (MediaQuery.of(context).size.height * 0.35);
      _scroll.animateTo(
        offset.clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      color: AppTheme.background.withValues(alpha: 0.97),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AppTheme.textPrimary,
                    ),
                    onPressed: widget.onClose,
                    splashRadius: 20,
                  ),
                  const Spacer(),
                  Text(
                    l10n.lyrics,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary.withValues(alpha: 0.8),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black,
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black,
                  ],
                  stops: const [0.0, 0.08, 0.92, 1.0],
                ).createShader(bounds),
                blendMode: BlendMode.dstOut,
                child: ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).size.height * 0.15,
                    bottom: MediaQuery.of(context).size.height * 0.35,
                  ),
                  itemCount: widget.lyrics.length,
                  itemBuilder: (ctx, i) {
                    final l = widget.lyrics[i];
                    final cur = i == widget.line;
                    final past = i < widget.line;
                    return AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      style: TextStyle(
                        fontSize: cur ? 18 : 14,
                        fontWeight: cur ? FontWeight.w600 : FontWeight.w400,
                        color: cur
                            ? Colors.white
                            : past
                            ? Colors.white.withValues(alpha: 0.35)
                            : Colors.white.withValues(alpha: 0.5),
                        height: 1.6,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            if (cur)
                              Container(
                                width: 3,
                                height: 18,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: AppTheme.accentBlue,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            Expanded(
                              child: Text(l.text, textAlign: TextAlign.center),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Shared Sub-widgets
// ═══════════════════════════════════════════════════════════════

// ── Sheet Shell ──

class _SheetShell extends StatelessWidget {
  final String title;
  final Widget Function(ScrollController) builder;
  const _SheetShell({required this.title, required this.builder});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (ctx, scroll) {
        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.surfaceDark,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textTertiary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.textTertiary),
              Expanded(child: builder(scroll)),
            ],
          ),
        );
      },
    );
  }
}

// ── Effect Item ──

class _EffectItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Widget? trailing;
  const _EffectItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 54,
      color: AppTheme.textTertiary.withValues(alpha: 0.15),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final VoidCallback onChanged;
  const _Toggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 24,
      child: GestureDetector(
        onTap: onChanged,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: value
                ? AppTheme.accentBlue
                : AppTheme.textTertiary.withValues(alpha: 0.3),
          ),
          padding: const EdgeInsets.all(2),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Album Cover ──

class _AlbumCover extends StatefulWidget {
  final Color color;
  const _AlbumCover({required this.color});

  @override
  State<_AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<_AlbumCover>
    with SingleTickerProviderStateMixin {
  double _tiltX = 0, _tiltY = 0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.5;

    return GestureDetector(
      onPanUpdate: (d) {
        setState(() {
          _tiltX = ((d.localPosition.dx - size / 2) / size * 0.06).clamp(
            -0.03,
            0.03,
          );
          _tiltY = ((d.localPosition.dy - size / 2) / size * 0.06).clamp(
            -0.03,
            0.03,
          );
        });
      },
      onPanEnd: (_) => setState(() {
        _tiltX = 0;
        _tiltY = 0;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateX(_tiltY)
          ..rotateY(_tiltX),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5),
                blurRadius: 40,
                spreadRadius: 5,
                offset: Offset(_tiltX * 200, _tiltY * 200),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.music_note_rounded,
              color: Colors.white.withValues(alpha: 0.2),
              size: size * 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

// ── NowPlaying Indicator ──

class _NowPlayingIndicator extends StatefulWidget {
  const _NowPlayingIndicator();

  @override
  State<_NowPlayingIndicator> createState() => _NowPlayingIndicatorState();
}

class _NowPlayingIndicatorState extends State<_NowPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (_, a) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(3, (i) {
          final h = 6 + (_ac.value + i * 0.3) % 1.0 * 10;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 2,
              height: h.clamp(4.0, 16.0),
              decoration: BoxDecoration(
                color: AppTheme.accentBlue,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ── Tag ──

class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Tag({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
