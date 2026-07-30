import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../features/playback/view_models/playback_provider.dart';
import '../theme/app_theme.dart';
import 'sheet_shell.dart';

class EffectsSheet extends StatelessWidget {
  const EffectsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final dsp = player.dspSettings;
    return SheetShell(
      title: l10n.soundSettings,
      builder: (scroll) {
        return ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
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
                ? AppTheme.brand
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
