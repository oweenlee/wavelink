import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/song.dart';
import '../view_models/playback_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/progress_slider_widget.dart';
import '../../../core/widgets/spectrum_bar.dart';
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
                            AlbumCover(color: song.dominantColor),
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
                    if (player.showSpectrum)
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
                child: LyricsOverlay(
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
