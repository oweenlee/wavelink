import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../domain/models/lyric_line.dart';
import '../theme/app_theme.dart';

class LyricsOverlay extends StatefulWidget {
  final List<LyricLine> lyrics;
  final int line;
  final VoidCallback onClose;
  final String? coverUrl;
  final int positionMs;
  final int durationMs;
  final bool blurred;

  const LyricsOverlay({
    super.key,
    required this.lyrics,
    required this.line,
    required this.onClose,
    this.coverUrl,
    this.positionMs = 0,
    this.durationMs = 0,
    this.blurred = true,
  });

  @override
  State<LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends State<LyricsOverlay> {
  final _scroll = ScrollController();
  int _prev = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void didUpdateWidget(LyricsOverlay old) {
    super.didUpdateWidget(old);
    if (widget.line != _prev && widget.line >= 0 && widget.lyrics.isNotEmpty) {
      _prev = widget.line;
      _scrollToCurrent();
    }
  }

  void _scrollToCurrent() {
    if (!_scroll.hasClients) return;
    final offset = widget.line * 48.0 -
        (MediaQuery.of(context).size.height * 0.4);
    _scroll.animateTo(
      offset.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _fmtMs(int ms) {
    final sec = (ms / 1000).floor();
    final min = sec ~/ 60;
    final s = sec % 60;
    return '${min.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _fmtRemaining(int ms) {
    final remaining = widget.durationMs - ms;
    final sec = (remaining / 1000).abs().floor();
    final min = sec ~/ 60;
    final s = sec % 60;
    return '-${min.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop: cover blur + dark overlay (or fallback gradient)
          _Backdrop(coverUrl: widget.coverUrl, blurred: widget.blurred),

          // Content
          SafeArea(
            child: Column(
              children: [
                // Top bar: mono tag + close
                _TopBar(onClose: widget.onClose),
                // Scrollable lyrics
                Expanded(
                  child: _LyricsList(
                    scroll: _scroll,
                    lyrics: widget.lyrics,
                    currentLine: widget.line,
                  ),
                ),
                // Bottom progress bar
                _BottomProgress(
                  positionMs: widget.positionMs,
                  durationMs: widget.durationMs,
                  fmtMs: _fmtMs,
                  fmtRemaining: _fmtRemaining,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  final String? coverUrl;
  final bool blurred;
  const _Backdrop({required this.coverUrl, this.blurred = true});

  @override
  Widget build(BuildContext context) {
    if (coverUrl != null && coverUrl!.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // 封面始终显示：打开动画期间为清晰图，模糊层淡入后才变模糊
          Image.file(
            File(coverUrl!),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallbackGradient(),
          ),
          // 模糊层：opacity 0 时 Flutter 跳过绘制、零采样；淡入过渡平滑
          RepaintBoundary(
            child: AnimatedOpacity(
              opacity: blurred ? 1 : 0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return _fallbackGradient();
  }

  Widget _fallbackGradient() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.s2, AppTheme.s1, AppTheme.s0],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final VoidCallback onClose;
  const _TopBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          // Mono tag: green dot + label
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF4ADE80),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'LRC  ·  synced',
                style: WlText.mono(
                  fontSize: 9,
                  color: AppTheme.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Close button
          GestureDetector(
            onTap: onClose,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                LucideIcons.x,
                color: AppTheme.textSecondary,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsList extends StatelessWidget {
  final ScrollController scroll;
  final List<LyricLine> lyrics;
  final int currentLine;

  const _LyricsList({
    required this.scroll,
    required this.lyrics,
    required this.currentLine,
  });

  @override
  Widget build(BuildContext context) {
    if (lyrics.isEmpty) {
      return Center(
        child: Text(
          'No lyrics available',
          style: TextStyle(
            fontSize: 15,
            color: AppTheme.textTertiary,
            fontFamily: 'SpaceGrotesk',
          ),
        ),
      );
    }

    final screenH = MediaQuery.of(context).size.height;

    return ListView.builder(
      controller: scroll,
      padding: EdgeInsets.only(
        top: screenH * 0.18,
        bottom: screenH * 0.22,
      ),
      itemCount: lyrics.length,
      itemBuilder: (ctx, i) {
        final line = lyrics[i];
        final isCurrent = i == currentLine;
        final isPast = i < currentLine;

        double fontSize;
        FontWeight weight;
        Color color;

        if (isCurrent) {
          fontSize = 22;
          weight = FontWeight.w600;
          color = Colors.white;
        } else if (isPast) {
          fontSize = 15;
          weight = FontWeight.w400;
          color = Colors.white.withValues(alpha: 0.45);
        } else {
          fontSize = 18;
          weight = FontWeight.w400;
          color = Colors.white.withValues(alpha: 0.65);
        }

        return AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 300),
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: weight,
            color: color,
            fontFamily: 'SpaceGrotesk',
            height: 1.5,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 6),
            child: Text(
              line.text,
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}

class _BottomProgress extends StatelessWidget {
  final int positionMs;
  final int durationMs;
  final String Function(int) fmtMs;
  final String Function(int) fmtRemaining;

  const _BottomProgress({
    required this.positionMs,
    required this.durationMs,
    required this.fmtMs,
    required this.fmtRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final progress = durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.6),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                fmtMs(positionMs),
                style: WlText.mono(
                  fontSize: 10,
                  color: AppTheme.textTertiary,
                ),
              ),
              Text(
                fmtRemaining(positionMs),
                style: WlText.mono(
                  fontSize: 10,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
