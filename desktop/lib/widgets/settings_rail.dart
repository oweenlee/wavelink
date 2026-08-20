import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import 'settings_section.dart';

// ═══════════════════════════ 设置页左侧导航栏 ═══════════════════════════
//
// 自 screens/settings.dart 迁出。`nav_${key}` / `settings_back` Key
// 供 widget 测试定位。

/// 设置页左侧导航栏：品牌区 + 分区导航 + 底部引擎状态。
class SettingsRail extends StatelessWidget {
  final int activeIndex;
  final bool engineReady;
  final ValueChanged<int> onSelect;
  const SettingsRail({
    super.key,
    required this.activeIndex,
    required this.engineReady,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: AppTheme.s2,
        border: Border(right: BorderSide(color: AppTheme.highlightStrong)),
      ),
      child: Column(
        children: [
          // 品牌区
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Row(
              children: [
                Material(
                  color: AppTheme.s3,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    key: const Key('settings_back'),
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.highlightStrong),
                      ),
                      child: const Icon(LucideIcons.arrowLeft,
                          size: 18, color: AppTheme.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('WaveLink',
                        style: TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppTheme.textPrimary,
                            letterSpacing: -0.3)),
                    Text('设置 SETTINGS',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 10,
                            letterSpacing: 0.8)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppTheme.divider),
          // 分类导航
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              itemCount: kSettingsSections.length,
              itemBuilder: (c, i) {
                final m = kSettingsSections[i];
                return _RailItem(
                  key: Key('nav_${m.key}'),
                  icon: m.icon,
                  label: m.title,
                  subtitle: m.subtitle,
                  active: i == activeIndex,
                  accent: accent,
                  onTap: () => onSelect(i),
                );
              },
            ),
          ),
          // 底部引擎状态
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.divider)),
            ),
            child: EnginePill(ready: engineReady),
          ),
        ],
      ),
    );
  }
}

/// 导航单项：选中时强调色左侧条 + 图标着色 + s3 底。
class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: active ? AppTheme.s3 : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border(
                left: active
                    ? BorderSide(color: accent, width: 3)
                    : const BorderSide(color: Colors.transparent, width: 3),
              ),
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 17,
                    color: active ? accent : AppTheme.textTertiary),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                              color: active
                                  ? AppTheme.textPrimary
                                  : AppTheme.textSecondary,
                              fontSize: 13,
                              fontWeight:
                                  active ? FontWeight.w600 : FontWeight.w400)),
                      if (subtitle != null && !active)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(subtitle!,
                              style: const TextStyle(
                                  color: AppTheme.textTertiary, fontSize: 10.5)),
                        ),
                    ],
                  ),
                ),
                if (active)
                  Icon(LucideIcons.chevronRight,
                      size: 14, color: accent.withAlpha(0x66)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
