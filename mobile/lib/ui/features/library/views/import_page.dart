import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../playback/view_models/playback_controller.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../../../core/theme/app_theme.dart';

/// Shows the import music bottom sheet (aligned with HTML prototype).
void showImportSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ImportSheet(),
  );
}

class _ImportSheet extends ConsumerStatefulWidget {
  const _ImportSheet();

  @override
  ConsumerState<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<_ImportSheet> {
  bool _scanning = false;
  String? _scanResult;

  @override
  Widget build(BuildContext context) {
    final prefs = PreferencesService.instance;
    // NAS 无需「启用」开关（配置了即视为启用）：
    // 已配置 host 即显示连接状态点
    final nasConnected = prefs.nasHost?.isNotEmpty == true;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.82,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.s0,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Sheet handle ──
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.s4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Header ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Import Music',
                        style: WlText.display(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Add songs to your library',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Text(
                      'Done',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.accentFallback,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Body ──
            Flexible(
              child: _SourceList(
                  scanning: _scanning,
                  scanResult: _scanResult,
                  nasConnected: nasConnected,
                  onDiscover: () => _handleDiscover(context),
                  onPickFiles: _handlePickFiles,
                  // 进入 NAS 配置页；保存成功返回 true 时关闭导入 sheet，回到曲库
                  onNas: () async {
                    final saved = await context.push<bool>('/nas');
                    if (saved == true && context.mounted) {
                      Navigator.of(context, rootNavigator: true).pop();
                    }
                  },
            ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Handlers ──

  Future<void> _handleDiscover(BuildContext context) async {
    final player = ref.read(playbackControllerProvider);
    setState(() {
      _scanning = true;
      _scanResult = null;
    });
    final ok = await player.discoverSongs();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _scanResult = ok ? 'Found songs' : 'No new songs found';
    });
  }

  Future<void> _handlePickFiles() async {
    final player = ref.read(playbackControllerProvider);
    final count = await player.importFromPicker();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (count > 0) {
      Fluttertoast.showToast(
        msg: l10n.importN(count),
        gravity: ToastGravity.BOTTOM,
        fontSize: 13,
        backgroundColor: AppTheme.ok,
        textColor: AppTheme.textPrimary,
      );
    }
  }
}

// ═══════════════════════════════════════════════════════════
// Source List (main view)
// ═══════════════════════════════════════════════════════════

class _SourceList extends StatelessWidget {
  final bool scanning;
  final String? scanResult;
  final bool nasConnected;
  final VoidCallback onDiscover;
  final VoidCallback onPickFiles;
  final VoidCallback onNas;

  const _SourceList({
    required this.scanning,
    required this.scanResult,
    required this.nasConnected,
    required this.onDiscover,
    required this.onPickFiles,
    required this.onNas,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        // ── Primary: Discover Songs ──
        _SourceRow.primary(
          icon: LucideIcons.search,
          title: l10n.discoverSongs,
          subtitle: l10n.discoverSongsHint,
          loading: scanning,
          resultMessage: scanResult,
          onTap: scanning ? null : onDiscover,
        ),

        // ── Pick Files ──
        _SourceRow(
          icon: LucideIcons.folderOpen,
          title: l10n.pickFiles,
          subtitle: l10n.pickFilesHint,
          onTap: onPickFiles,
        ),

        // ── NAS (SMB) ──
        _SourceRow(
          icon: LucideIcons.hardDrive,
          title: l10n.scanSmb,
          subtitle: l10n.importSmbHint,
          status: nasConnected ? l10n.nasConnected : l10n.nasDisconnected,
          statusOn: nasConnected,
          onTap: onNas,
        ),

        // ── Format footnote ──
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: AppTheme.s2, width: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SUPPORTED FORMATS',
                style: WlText.mono(
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textTertiary,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.supportedFormats,
                style: WlText.mono(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textTertiary.withValues(alpha: 0.6),
                  letterSpacing: 0.3,
                ).copyWith(height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════
// Source Row (list item with bottom border)
// ═══════════════════════════════════════════════════════════

class _SourceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool isPrimary;
  final bool loading;
  final String? resultMessage;
  final String? status;
  final bool statusOn;

  const _SourceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.status,
    this.statusOn = false,
  }) : isPrimary = false,
       loading = false,
       resultMessage = null;

  const _SourceRow.primary({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.loading = false,
    this.resultMessage,
  }) : isPrimary = true,
       status = null,
       statusOn = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.accentFallback;

    return Container(
      margin: isPrimary
          ? const EdgeInsets.fromLTRB(20, 0, 20, 4)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: isPrimary ? accent.withValues(alpha: 0.08) : null,
        borderRadius: isPrimary ? BorderRadius.circular(10) : null,
        border: isPrimary
            ? Border.all(color: accent.withValues(alpha: 0.15), width: 1)
            : const Border(
                bottom: BorderSide(color: AppTheme.s2, width: 0.5),
              ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: isPrimary ? BorderRadius.circular(10) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              // Icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isPrimary ? accent : AppTheme.s2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: loading
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isPrimary ? Colors.white : accent,
                        ),
                      )
                    : Icon(
                        icon,
                        color: isPrimary ? Colors.white : AppTheme.textSecondary,
                        size: 20,
                      ),
              ),
              const SizedBox(width: 12),

              // Title + subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      resultMessage ?? subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: resultMessage != null
                            ? AppTheme.ok
                            : AppTheme.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Status chip (optional)
              if (status != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusOn
                        ? AppTheme.ok.withValues(alpha: 0.12)
                        : AppTheme.s3,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    status!,
                    style: WlText.mono(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: statusOn ? AppTheme.ok : AppTheme.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],

              // Chevron
              Icon(
                LucideIcons.chevronRight,
                color: AppTheme.textTertiary.withValues(alpha: 0.5),
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

