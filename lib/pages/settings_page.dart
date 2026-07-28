import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../providers/playback_provider.dart';
import '../providers/locale_provider.dart';

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
        _Section(
          title: l10n.settingsAudio,
          children: [
            _SwitchItem(
              icon: Icons.tune_rounded,
              label: l10n.dspPipeline,
              value: dsp.enabled,
              onChanged: (_) => player.toggleDspEnabled(),
            ),
            _SwitchItem(
              icon: Icons.graphic_eq_rounded,
              label: l10n.dspCrossfeed,
              value: dsp.crossfeed,
              onChanged: (_) => player.toggleCrossfeed(),
            ),
            _SwitchItem(
              icon: Icons.arrow_right_alt_rounded,
              label: l10n.stereoWidening,
              value: dsp.widener,
              onChanged: (_) => player.toggleWidener(),
            ),
            _SwitchItem(
              icon: Icons.volume_up_rounded,
              label: l10n.truePeakLimiter,
              value: dsp.limiter,
              onChanged: (_) => player.toggleLimiter(),
            ),
            _SwitchItem(
              icon: Icons.blur_on_rounded,
              label: l10n.tpdfDither,
              value: dsp.dither,
              onChanged: (_) => player.toggleDither(),
            ),
            _SwitchItem(
              icon: Icons.auto_awesome_rounded,
              label: l10n.replayGain,
              value: player.replayGain,
              onChanged: (_) => player.setReplayGain(!player.replayGain),
            ),
            _EqPresetSelector(),
            _SettingItem(
              icon: Icons.volume_up_rounded,
              label: l10n.outputDevice,
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.settingsAppearance,
          children: [
            _SettingItem(
              icon: Icons.palette_rounded,
              label: l10n.theme,
              trailing: l10n.themeDark,
              onTap: () {},
            ),
            _SwitchItem(
              icon: Icons.colorize_rounded,
              label: l10n.dynamicColor,
              value: player.dynamicColor,
              onChanged: (_) => player.setDynamicColor(!player.dynamicColor),
            ),
            _SliderItem(
              icon: Icons.blur_on_rounded,
              label: l10n.coverBlur,
              value: player.coverBlur,
              onChanged: player.setCoverBlur,
            ),
            _SwitchItem(
              icon: Icons.bar_chart_rounded,
              label: l10n.showSpectrum,
              value: player.showSpectrum,
              onChanged: (v) => player.setShowSpectrum(v),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.settingsLibrary,
          children: [
            _ActionItem(
              icon: Icons.library_music_rounded,
              label: l10n.scanMusicLibrary,
              onTap: () async {
                final player = context.read<PlaybackProvider>();
                final ok = await player.scanMediaStore();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok ? l10n.scanComplete : l10n.scanNoPermission),
                      backgroundColor: ok ? AppTheme.accentBlue : AppTheme.danger,
                    ),
                  );
                }
              },
            ),
            _ActionItem(
              icon: Icons.folder_rounded,
              label: l10n.scanDir,
              onTap: () async {
                final player = context.read<PlaybackProvider>();
                await player.importFromPicker();
              },
            ),
            _ActionItem(
              icon: Icons.refresh_rounded,
              label: l10n.rescanLibrary,
              onTap: () => context.read<PlaybackProvider>().rescanImported(),
            ),
            _SettingItem(
              icon: Icons.file_upload_outlined,
              label: l10n.importExportPlaylist,
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.language,
          children: [
            _LanguageSelector(),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.settingsAbout,
          children: [
            _SettingItem(
              icon: Icons.info_outline_rounded,
              label: l10n.version,
              trailing: l10n.versionValue,
              onTap: () {},
            ),
            _SettingItem(icon: Icons.code_rounded, label: l10n.licenses, onTap: () {}),
            _SettingItem(
              icon: Icons.bug_report_rounded,
              label: l10n.audioDiagnostic,
              onTap: () => context.push('/diagnostic'),
            ),
          ],
        ),
      ],
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector();

  static const _options = [
    ('system', ''),
    ('zh', ''),
    ('en', ''),
  ];

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
            selectedColor: AppTheme.accentBlue.withValues(alpha: 0.2),
            labelStyle: TextStyle(
              color: selected ? AppTheme.accentBlue : AppTheme.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
            backgroundColor: AppTheme.surfaceDark,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: selected
                    ? AppTheme.accentBlue
                    : AppTheme.textTertiary.withValues(alpha: 0.2),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _EqPresetSelector extends StatelessWidget {
  const _EqPresetSelector();

  static const _presets = [
    EqPresetKind.flat,
    EqPresetKind.rock,
    EqPresetKind.pop,
    EqPresetKind.dance,
    EqPresetKind.classical,
    EqPresetKind.soft,
    EqPresetKind.fullBass,
    EqPresetKind.fullTreble,
    EqPresetKind.techno,
    EqPresetKind.vocals,
  ];

  String _label(AppLocalizations l10n, EqPresetKind k) {
    return switch (k) {
      EqPresetKind.flat => l10n.eqPresetFlat,
      EqPresetKind.rock => l10n.eqPresetRock,
      EqPresetKind.pop => l10n.eqPresetPop,
      EqPresetKind.dance => l10n.eqPresetDance,
      EqPresetKind.classical => l10n.eqPresetClassical,
      EqPresetKind.soft => l10n.eqPresetSoft,
      EqPresetKind.fullBass => l10n.eqPresetFullBass,
      EqPresetKind.fullTreble => l10n.eqPresetFullTreble,
      EqPresetKind.techno => l10n.eqPresetTechno,
      EqPresetKind.vocals => l10n.eqPresetVocals,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.eq10Band,
            style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((kind) {
              final selected = player.dspSettings.preset == kind;
              return ChoiceChip(
                label: Text(_label(l10n, kind)),
                selected: selected,
                onSelected: (_) => player.applyEqPreset(kind),
                selectedColor: AppTheme.accentBlue.withValues(alpha: 0.2),
                labelStyle: TextStyle(
                  color: selected ? AppTheme.accentBlue : AppTheme.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                backgroundColor: AppTheme.surfaceDark,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: selected
                        ? AppTheme.accentBlue
                        : AppTheme.textTertiary.withValues(alpha: 0.2),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
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
  final VoidCallback onTap;

  const _SettingItem({
    required this.icon,
    required this.label,
    this.trailing,
    required this.onTap,
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
          : const Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.textTertiary,
              size: 20,
            ),
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
        activeThumbColor: AppTheme.accentBlue,
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: AppTheme.accentBlue,
                    inactiveTrackColor: AppTheme.textTertiary.withValues(
                      alpha: 0.3,
                    ),
                    thumbColor: AppTheme.accentBlue,
                    overlayColor: AppTheme.accentBlue.withValues(alpha: 0.1),
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
      leading: Icon(icon, color: AppTheme.accentBlue, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.accentBlue),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}
