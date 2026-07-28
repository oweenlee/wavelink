import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class TransportControls extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onSkipForward;
  final VoidCallback onSkipBack;

  const TransportControls({
    super.key,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrevious,
    required this.onSkipForward,
    required this.onSkipBack,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ControlButton(
          icon: Icons.skip_previous_rounded,
          size: 44,
          onTap: onSkipBack,
        ),
        const SizedBox(width: 8),
        _ControlButton(
          icon: Icons.fast_rewind_rounded,
          size: 44,
          onTap: onPrevious,
        ),
        const SizedBox(width: 16),
        _PlayButton(isPlaying: isPlaying, onTap: onPlayPause),
        const SizedBox(width: 16),
        _ControlButton(
          icon: Icons.fast_forward_rounded,
          size: 44,
          onTap: onNext,
        ),
        const SizedBox(width: 8),
        _ControlButton(
          icon: Icons.skip_next_rounded,
          size: 44,
          onTap: onSkipForward,
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onTap;

  const _PlayButton({required this.isPlaying, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: AppTheme.accentBlue,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppTheme.accentBlue.withValues(alpha: 0.3),
              blurRadius: 12,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 32,
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: Icon(icon, color: AppTheme.textPrimary, size: 24),
      ),
    );
  }
}
