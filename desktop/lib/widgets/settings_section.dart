import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';

// ═══════════════════════════ 设置页内容框架 ═══════════════════════════
//
// 自 screens/settings.dart 迁出：分区元信息、内容区（页头 + 横幅 + 内容）
// 与引擎状态胶囊。`sec_${key}` / 引擎胶囊 Key 供 widget 测试定位。
// 标题/副标题按分区 key 从 l10n 解析（与移动端一致，禁止硬编码文案）。

/// 导航分类元信息（测试 Key 前缀 + 图标）。
class SettingsSectionMeta {
  final String key;
  final IconData icon;
  const SettingsSectionMeta(this.key, this.icon);
}

/// 设置页全部分区（顺序即导航顺序）。
const kSettingsSections = <SettingsSectionMeta>[
  SettingsSectionMeta('general', LucideIcons.settings),
  SettingsSectionMeta('audio', LucideIcons.volume2),
  SettingsSectionMeta('dsp', LucideIcons.slidersHorizontal),
  SettingsSectionMeta('diag', LucideIcons.activity),
];

/// 分区标题（按 key 解析 l10n）。
String settingsSectionTitle(AppLocalizations l, String key) => switch (key) {
      'general' => l.settingsSectionGeneral,
      'audio' => l.settingsSectionAudio,
      'dsp' => l.settingsSectionDsp,
      _ => l.settingsSectionDiag,
    };

/// 分区副标题（按 key 解析 l10n）。
String settingsSectionSubtitle(AppLocalizations l, String key) => switch (key) {
      'general' => l.settingsSectionGeneralSub,
      'audio' => l.settingsSectionAudioSub,
      'dsp' => l.settingsSectionDspSub,
      _ => l.settingsSectionDiagSub,
    };

/// 引擎健康度胶囊（页头与侧栏底部共用）。
class EnginePill extends StatelessWidget {
  final bool ready;
  const EnginePill({super.key, required this.ready});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final color = ready ? AppTheme.ok : AppTheme.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(0x14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(0x50)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(ready ? l.settingsEngineReady : l.settingsEngineNotReady,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 内容区：页头 + 引擎横幅 + 分类内容（限宽居中）。
class SettingsSectionContent extends StatelessWidget {
  final SettingsSectionMeta section;
  final bool engineNull;
  final Widget child;
  const SettingsSectionContent({
    super.key,
    required this.section,
    required this.engineNull,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(section: section, engineNull: engineNull),
              const SizedBox(height: 22),
              if (engineNull) const _EngineNullBanner(),
              child,
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// 页头：强调色图标块 + 标题 + 副标题 + 引擎状态胶囊。
class _PageHeader extends StatelessWidget {
  final SettingsSectionMeta section;
  final bool engineNull;
  const _PageHeader({required this.section, required this.engineNull});

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final l = AppLocalizations.of(context);
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accent.withAlpha(0x20),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(section.icon, size: 21, color: accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(settingsSectionTitle(l, section.key),
                  key: Key('sec_${section.key}'),
                  style: WlText.display(fontSize: 22)),
              const SizedBox(height: 2),
              Text(settingsSectionSubtitle(l, section.key),
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        EnginePill(ready: !engineNull),
      ],
    );
  }
}

/// 引擎未加载提示横幅。
class _EngineNullBanner extends StatelessWidget {
  const _EngineNullBanner();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.warn.withAlpha(0x0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warn.withAlpha(0x40)),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.alertCircle, size: 16, color: AppTheme.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.settingsEngineNullBanner,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
