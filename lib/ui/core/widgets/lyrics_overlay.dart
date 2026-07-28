import 'package:flutter/material.dart';
import '../../../domain/models/lyric_line.dart';
import '../theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

class LyricsOverlay extends StatefulWidget {
  final List<LyricLine> lyrics;
  final int line;
  final Color dominantColor;
  final VoidCallback onClose;

  const LyricsOverlay({
    super.key,
    required this.lyrics,
    required this.line,
    required this.dominantColor,
    required this.onClose,
  });

  @override
  State<LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends State<LyricsOverlay> {
  final _scroll = ScrollController();
  int _prev = -1;

  @override
  void didUpdateWidget(LyricsOverlay old) {
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
