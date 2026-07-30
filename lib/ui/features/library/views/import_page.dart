import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../playback/view_models/playback_provider.dart';
import '../../../core/theme/app_theme.dart';
import 'nas_settings_sheet.dart';

class ImportPage extends StatelessWidget {
  const ImportPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.read<PlaybackProvider>();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          l10n.importMusic,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _ImportOption(
            icon: Icons.library_music_rounded,
            color: AppTheme.brand,
            title: l10n.scanMusicLibrary,
            subtitle: l10n.importSystemMusicHint,
            onTap: () async {
              final ok = await player.scanMediaStore();
              if (!context.mounted) return;
              _showResult(context, ok);
            },
          ),
          _ImportOption(
            icon: Icons.folder_open_rounded,
            color: AppTheme.brand,
            title: l10n.scanDir,
            subtitle: l10n.importPickerHint,
            onTap: () async {
              final count = await player.importFromPicker();
              if (!context.mounted) return;
              if (count > 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.importN(count)),
                    backgroundColor: AppTheme.brand,
                  ),
                );
              }
            },
          ),
          _ImportOption(
            icon: Icons.cloud_rounded,
            color: AppTheme.brand,
            title: l10n.scanSubsonic,
            subtitle: l10n.importSubsonicHint,
            onTap: () async {
              final ok = await player.scanSubsonic();
              if (!context.mounted) return;
              _showResult(context, ok);
            },
          ),
          _ImportOption(
            icon: Icons.network_wifi_rounded,
            color: AppTheme.brand,
            title: l10n.scanSmb,
            subtitle: l10n.importSmbHint,
            onTap: () async {
              await _showNasSettings(context);
              if (!context.mounted) return;
              final prefs = PreferencesService.instance;
              if (!prefs.nasEnabled) return;
              final share = prefs.nasShare;
              if (share == null || share.isEmpty) return;
              final ok = await player.scanSmb(share);
              if (!context.mounted) return;
              _showResult(context, ok);
            },
          ),
          _ImportOption(
            icon: Icons.refresh_rounded,
            color: AppTheme.success,
            title: l10n.rescanLibrary,
            subtitle: l10n.rescanHint,
            onTap: () {
              player.rescanImported();
              Navigator.pop(context);
            },
          ),
          _ImportOption(
            icon: Icons.search_rounded,
            color: AppTheme.brand,
            title: l10n.scanAllSources,
            subtitle: l10n.scanAllHint,
            onTap: () async {
              await player.scanAllSources();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.scanComplete),
                  backgroundColor: AppTheme.brand,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showNasSettings(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const NasSettingsSheet(),
    );
  }

  void _showResult(BuildContext context, bool ok) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.scanComplete : l10n.scanNoPermission),
        backgroundColor: ok ? AppTheme.brand : AppTheme.danger,
      ),
    );
  }
}

class _ImportOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ImportOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textTertiary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
