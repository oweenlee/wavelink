import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/sheet_shell.dart';
import '../../../core/widgets/wl_toggle.dart';
import '../../playback/view_models/playback_controller.dart';
import '../view_models/dsp_provider.dart';
import '../view_models/locale_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final player = ref.watch(playbackControllerProvider);
    final dsp = ref.watch(dspProvider).dspSettings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        const SizedBox(height: 4),

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
              subtitle: _bitPerfectStatus(player),
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
                final player = ref.read(playbackControllerProvider);
                final ok = await player.discoverSongs();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok ? l10n.scanDone : l10n.scanNoPermission),
                      backgroundColor: ok
                          ? AccentScope.of(context)
                          : AppTheme.danger,
                    ),
                  );
                }
              },
            ),
            _ActionItem(
              icon: LucideIcons.folder,
              label: l10n.scanDir,
              onTap: () async {
                final player = ref.read(playbackControllerProvider);
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
        _Section(title: l10n.language, children: [_LanguageItem()]),
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

class _LanguageItem extends ConsumerWidget {
  const _LanguageItem();

  static const _options = ['system', 'zh', 'en'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final localeMode = ref.watch(localeProvider);

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

    return _SettingItem(
      icon: LucideIcons.globe,
      label: l10n.language,
      trailing: labelFor(localeMode, l10n),
      onTap: () => _showLanguageSheet(context, ref),
    );
  }

  Future<void> _showLanguageSheet(
    BuildContext context,
    WidgetRef ref,
  ) {
    final l10n = AppLocalizations.of(context);
    final localeMode = ref.read(localeProvider);
    final accent = AccentScope.of(context);

    String labelFor(String mode) {
      switch (mode) {
        case 'zh':
          return '中文';
        case 'en':
          return 'English';
        default:
          return l10n.systemDefault;
      }
    }

    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SheetShell(
        title: l10n.language,
        builder: (scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: _options.map((mode) {
            final selected = localeMode == mode;
            return ListTile(
              leading: Icon(
                selected ? LucideIcons.checkCircle2 : LucideIcons.circle,
                color: selected ? accent : AppTheme.textTertiary,
                size: 20,
              ),
              title: Text(
                labelFor(mode),
                style: TextStyle(
                  fontSize: 15,
                  color: selected ? accent : AppTheme.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              dense: true,
              onTap: () {
                ref.read(localeProvider.notifier).setMode(mode);
                Navigator.of(context).pop();
              },
            );
          }).toList(),
        ),
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
  final String? subtitle;

  const _SwitchItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.textSecondary, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textTertiary,
              ),
            ),
      trailing: WlToggle(
        value: value,
        // 与音效面板同一组件，开关视觉全局一致
        onChanged: () => onChanged(!value),
      ),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

/// bit-perfect 开关副标题：如实反映「有效」状态（偏好 + 实际链路 + DSP）。
String _bitPerfectStatus(PlaybackController player) {
  final t = player.telemetry;
  if (!player.bitPerfect) return '未开启';
  if (player.effectiveBitPerfect) {
    return Platform.isAndroid ? 'Exclusive 直通生效中' : 'bit-exact（速率匹配）生效中';
  }
  final reasons = <String>[];
  if (t.fileRate > 0 && t.fileRate != t.outputRate) {
    reasons.add('重采样中');
  }
  if (Platform.isAndroid && t.outputMode == 2) {
    reasons.add('Shared 降级');
  }
  if (player.dspAffectingSignal) {
    reasons.add('DSP 未旁路');
  }
  if (reasons.isEmpty) reasons.add('等待播放');
  return '未生效：${reasons.join(' / ')}';
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
    final accent = AccentScope.of(context);
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
                    // 与特效面板滑杆同款配色
                    activeTrackColor: accent,
                    inactiveTrackColor: AppTheme.textTertiary.withValues(
                      alpha: 0.3,
                    ),
                    thumbColor: accent,
                    overlayColor: accent.withValues(alpha: 0.08),
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
    final accent = AccentScope.of(context);
    return ListTile(
      leading: Icon(icon, color: accent, size: 22),
      title: Text(
        label,
        style: TextStyle(fontSize: 15, color: accent),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}
