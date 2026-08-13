import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../playback/view_models/playback_controller.dart';

/// AutoEQ 耳机校正档案选择页（独立全屏页，替代底部 sheet）。
/// 选中即时生效，与手动 EQ 互斥（见 DspNotifier）。
class AutoEqSettingsPage extends ConsumerStatefulWidget {
  const AutoEqSettingsPage({super.key});

  @override
  ConsumerState<AutoEqSettingsPage> createState() => _AutoEqSettingsPageState();
}

class _AutoEqSettingsPageState extends ConsumerState<AutoEqSettingsPage> {
  late final Future<List<String>> _catalog;

  @override
  void initState() {
    super.initState();
    _catalog = ref.read(playbackControllerProvider).getAutoEqCatalog();
  }

  void _select(String? model) {
    ref.read(playbackControllerProvider).setAutoEq(model);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    final current = ref.watch(playbackControllerProvider).autoEqModel;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.autoEq),
        centerTitle: true,
        backgroundColor: AppTheme.surfaceDark,
        leading: IconButton(
          icon: const Icon(
            LucideIcons.arrowLeft,
            color: AppTheme.textSecondary,
          ),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<List<String>>(
          future: _catalog,
          builder: (context, snap) {
            final models = snap.data ?? const <String>[];
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    l10n.autoEqHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      _ModelTile(
                        title: l10n.autoEqOff,
                        selected: current == null,
                        accent: accent,
                        onTap: () => _select(null),
                      ),
                      if (!snap.hasData)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ...models.map(
                        (model) => _ModelTile(
                          title: model,
                          selected: current == model,
                          accent: accent,
                          onTap: () => _select(model),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 档案单选项（选中态 accent 高亮 + 对勾）
class _ModelTile extends StatelessWidget {
  final String title;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _ModelTile({
    required this.title,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        selected ? LucideIcons.checkCircle2 : LucideIcons.circle,
        color: selected ? accent : AppTheme.textTertiary,
        size: 20,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          color: selected ? accent : AppTheme.textPrimary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      dense: true,
      onTap: onTap,
    );
  }
}
