import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../playback/view_models/playback_provider.dart';
import '../view_models/locale_provider.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final dsp = player.dspSettings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 24),
          child: Text(
            'SETTINGS',
            style: WlText.display(
              fontSize: 28,
              letterSpacing: 0.18 * 28,
            ),
          ),
        ),
        _Section(
          title: l10n.settingsAudio,
          children: [
            _SwitchItem(
              icon: LucideIcons.slidersHorizontal,
              label: l10n.dspPipeline,
              value: dsp.enabled,
              onChanged: (_) => player.toggleDspEnabled(),
            ),
            _SwitchItem(
              icon: LucideIcons.activity,
              label: l10n.dspCrossfeed,
              value: dsp.crossfeed,
              onChanged: (_) => player.toggleCrossfeed(),
            ),
            _SwitchItem(
              icon: LucideIcons.arrowRight,
              label: l10n.stereoWidening,
              value: dsp.widener,
              onChanged: (_) => player.toggleWidener(),
            ),
            _SwitchItem(
              icon: LucideIcons.volume2,
              label: l10n.truePeakLimiter,
              value: dsp.limiter,
              onChanged: (_) => player.toggleLimiter(),
            ),
            _SwitchItem(
              icon: LucideIcons.droplets,
              label: l10n.tpdfDither,
              value: dsp.dither,
              onChanged: (_) => player.toggleDither(),
            ),
            _SwitchItem(
              icon: LucideIcons.sparkles,
              label: l10n.replayGain,
              value: player.replayGain,
              onChanged: (_) => player.setReplayGain(!player.replayGain),
            ),
            _SwitchItem(
              icon: LucideIcons.badgeCheck,
              label: l10n.bitPerfect,
              value: player.bitPerfect,
              onChanged: (_) => player.setBitPerfect(!player.bitPerfect),
            ),
            _SettingItem(
              icon: LucideIcons.volume2,
              label: l10n.outputDevice,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.settingsAppearance,
          children: [
            _SettingItem(
              icon: LucideIcons.palette,
              label: l10n.theme,
              trailing: l10n.themeDark,
            ),
            _SwitchItem(
              icon: LucideIcons.pipette,
              label: l10n.dynamicColor,
              value: player.dynamicColor,
              onChanged: (_) => player.setDynamicColor(!player.dynamicColor),
            ),
            _SliderItem(
              icon: LucideIcons.droplets,
              label: l10n.coverBlur,
              value: player.coverBlur,
              onChanged: player.setCoverBlur,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.settingsLibrary,
          children: [
            _ActionItem(
              icon: LucideIcons.library,
              label: l10n.discoverSongs,
              onTap: () async {
                final player = context.read<PlaybackProvider>();
                final ok = await player.discoverSongs();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok ? l10n.scanDone : l10n.scanNoPermission),
                      backgroundColor: ok ? AppTheme.brand : AppTheme.danger,
                    ),
                  );
                }
              },
            ),
            _ActionItem(
              icon: LucideIcons.folder,
              label: l10n.scanDir,
              onTap: () async {
                final player = context.read<PlaybackProvider>();
                await player.importFromPicker();
              },
            ),
            _SettingItem(
              icon: LucideIcons.upload,
              label: l10n.importExportPlaylist,
              trailing: 'Coming soon',
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(title: l10n.language, children: [_LanguageSelector()]),
        const SizedBox(height: 24),
        _Section(
          title: l10n.settingsAbout,
          children: [
            _SettingItem(
              icon: LucideIcons.info,
              label: l10n.version,
              trailing: l10n.versionValue,
            ),
          ],
        ),
      ],
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector();

  static const _options = [('system', ''), ('zh', ''), ('en', '')];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = context.watch<LocaleProvider>();

    // 跟随系统项的显示名需要本地化
    String labelFor(String mode, AppLocalizations l) {
      switch (mode) {
        case 'zh':
          return '中文';
        case 'en':
          return 'English';
        default:
          return l.systemDefault;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        children: _options.map((opt) {
          final selected = locale.mode == opt.$1;
          final label = labelFor(opt.$1, l10n);
          return ChoiceChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => locale.setMode(opt.$1),
            selectedColor: AppTheme.surfaceHigh,
            labelStyle: TextStyle(
              color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
            backgroundColor: AppTheme.surfaceDark,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: selected
                    ? AppTheme.textSecondary
                    : AppTheme.textTertiary.withValues(alpha: 0.2),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceDark.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: children.asMap().entries.map((entry) {
                return Column(
                  children: [
                    if (entry.key > 0) const Divider(height: 1, indent: 52),
                    entry.value,
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback? onTap;

  const _SettingItem({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.textSecondary, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      ),
      trailing: trailing != null
          ? Text(
              trailing!,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textTertiary,
              ),
            )
          : onTap != null
              ? const Icon(
                  LucideIcons.chevronRight,
                  color: AppTheme.textTertiary,
                  size: 20,
                )
              : null,
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

class _SwitchItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.textSecondary, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppTheme.textPrimary,
      ),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

class _SliderItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _SliderItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 22),
          const SizedBox(width: 16),
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
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: AppTheme.textPrimary,
                    inactiveTrackColor: AppTheme.textTertiary.withValues(
                      alpha: 0.3,
                    ),
                    thumbColor: AppTheme.textPrimary,
                    overlayColor: AppTheme.textPrimary.withValues(alpha: 0.08),
                  ),
                  child: Slider(value: value, onChanged: onChanged),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.brand, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.brand),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}
