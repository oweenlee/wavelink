import 'package:flutter/material.dart';

import '../core/theme.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface2 = kSurface2;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;

/// 侧栏完整形态导航项：图标 + 标签 + 计数 + 可选尾随操作按钮，
/// 选中态为左侧强调色条 + 高亮底（对齐 mobile 列表选中态语言）。
class NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final bool active;
  final VoidCallback onTap;
  final List<Widget>? trailingActions;

  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    this.trailing,
    this.active = false,
    required this.onTap,
    this.trailingActions,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(icon,
              size: 17, color: active ? accent : AppTheme.textTertiary),
          const SizedBox(width: 11),
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: active ? _onSurface : _onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ),
          if (trailing != null)
            Text(trailing!,
                style: const TextStyle(
                    color: AppTheme.textTertiary, fontSize: 11)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          // 选中态左侧强调色条
          Container(
            width: 3,
            height: 26,
            decoration: BoxDecoration(
              color: active ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Material(
              color: active ? _surface2 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: body,
              ),
            ),
          ),
          if (trailingActions != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: trailingActions!,
              ),
            ),
        ],
      ),
    );
  }
}

/// 侧栏紧凑形态导航项（Tooltip + 选中态左侧 accent 色条）。
/// 窄窗口（<720px）下侧栏折叠为图标条时使用，对齐主流桌面播放器。
class NavItemCompact extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const NavItemCompact({
    super.key,
    required this.icon,
    required this.tooltip,
    this.active = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? _surface2 : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                    color: active ? accent : Colors.transparent, width: 3),
              ),
            ),
            child: Icon(icon,
                size: 19, color: active ? accent : AppTheme.textTertiary),
          ),
        ),
      ),
    );
  }
}
