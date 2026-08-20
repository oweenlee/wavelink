import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 设置分组卡片：带图标标题头 + 子项列表（自动分隔线）。
/// （从 settings.dart 迁出为公共组件，对齐 mobile「可复用组件收进
/// core/widgets」的组织方式。）
class SettingGroup extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? description;
  final List<Widget> tiles;

  const SettingGroup({
    super.key,
    this.icon,
    required this.title,
    this.description,
    required this.tiles,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.s2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.highlightStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分组头
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: AppTheme.textTertiary),
                  const SizedBox(width: 8),
                ],
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(description!,
                  style: const TextStyle(
                      color: AppTheme.textTertiary, fontSize: 12)),
            )
          else
            const SizedBox(height: 4),
          // 子项（自动分隔线）
          ..._tilesWithDividers(tiles),
        ],
      ),
    );
  }

  List<Widget> _tilesWithDividers(List<Widget> tiles) {
    final result = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      result.add(tiles[i]);
      if (i < tiles.length - 1) {
        result.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Divider(height: 1, thickness: 1, color: AppTheme.divider),
        ));
      }
    }
    result.add(const SizedBox(height: 6));
    return result;
  }
}

/// 统一设置项：图标 + 标题/描述 + 尾部控件或子内容。
///
/// [trailing] 用于开关/下拉等紧凑控件；[child] 用于滑块等需要整行的内容。
/// 两者不应同时使用。
class SettingTile extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? description;
  final Color? iconColor;
  final Widget? trailing;
  final Widget? child;
  final VoidCallback? onTap;

  const SettingTile({
    super.key,
    this.icon,
    required this.title,
    this.description,
    this.iconColor,
    this.trailing,
    this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 16, color: iconColor ?? AppTheme.textTertiary),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500)),
                    if (description != null) ...[
                      const SizedBox(height: 3),
                      Text(description!,
                          style: const TextStyle(
                              color: AppTheme.textTertiary, fontSize: 11.5)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          if (child != null) ...[
            const SizedBox(height: 10),
            child!,
          ],
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, child: content),
      );
    }
    return content;
  }
}
