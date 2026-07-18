import 'package:flutter/material.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  const SongTile({
    super.key,
    required this.song,
    this.isPlaying = false,
    this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Album art placeholder
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: song.dominantColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: isPlaying ? const Center(child: _EqualizerBars()) : null,
            ),
            const SizedBox(width: 12),
            // Title & artist
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isPlaying ? FontWeight.w600 : FontWeight.w400,
                      color: isPlaying
                          ? AppTheme.accentBlue
                          : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} · ${song.album}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Duration
            Text(
              song.formattedDuration,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textTertiary,
              ),
            ),
            const SizedBox(width: 8),
            // More button
            GestureDetector(
              onTap: onMore,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.more_horiz_rounded,
                  size: 20,
                  color: AppTheme.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerBars extends StatefulWidget {
  const _EqualizerBars();

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final phase = i * 0.3;
            final h = 6 + (_controller.value + phase).abs() % 1.0 * 10;
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
        );
      },
    );
  }
}
