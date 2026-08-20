import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';

// ═══════════════════════════ 设置页内容框架 ═══════════════════════════
//
// 自 screens/settings.dart 迁出：分区元信息、内容区（页头 + 横幅 + 内容）
// 与引擎状态胶囊。`sec_${key}` / 引擎胶囊 Key 供 widget 测试定位。

/// 导航分类元信息（图标 + 标题 + 副标题 + 测试 Key 前缀）。
class SettingsSectionMeta {
  final String key;
  final String title;
  final IconData icon;
  final String subtitle;
  const SettingsSectionMeta(this.key, this.title, this.icon, this.subtitle);
}

/// 设置页全部分区（顺序即导航顺序）。
const kSettingsSections = <SettingsSectionMeta>[
  SettingsSectionMeta('general', '通用', LucideIcons.settings, '语言与数据管理'),
  SettingsSectionMeta('audio', '音频输出', LucideIcons.volume2, '设备选择与采样率'),
  SettingsSectionMeta('dsp', 'DSP 效果', LucideIcons.slidersHorizontal, '实时音频处理链'),
  SettingsSectionMeta('diag', '诊断', LucideIcons.activity, '引擎运行指标'),
];

/// 引擎健康度胶囊（页头与侧栏底部共用）。
class EnginePill extends StatelessWidget {
  final bool ready;
  const EnginePill({super.key, required this.ready});

  @override
  Widget build(BuildContext context) {
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
          Text(ready ? '引擎就绪' : '引擎未加载',
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
              Text(section.title,
                  key: Key('sec_${section.key}'),
                  style: WlText.display(fontSize: 22)),
              const SizedBox(height: 2),
              Text(section.subtitle,
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
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.warn.withAlpha(0x0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warn.withAlpha(0x40)),
      ),
      child: const Row(
        children: [
          Icon(LucideIcons.alertCircle, size: 16, color: AppTheme.warn),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '音频引擎未加载（缺少动态库），DSP / 设备设置不可用。',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
