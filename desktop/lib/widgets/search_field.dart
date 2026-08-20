import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

/// 统一搜索框：圆角容器 + 搜索图标 + 输入 + 有内容时显示清除按钮。
/// 此前曲库视图与媒体视图各内联一份近似实现，合并为此组件
/// （对齐 mobile「核心交互组件收进 ui/core/widgets」的组织方式）。
class SearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;

  const SearchField({
    super.key,
    required this.controller,
    this.focusNode,
    required this.onChanged,
  });

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _hasText = widget.controller.text.isNotEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() =>
      setState(() => _hasText = widget.controller.text.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Icon(LucideIcons.search,
                size: 18, color: AppTheme.textTertiary),
          ),
          Expanded(
            child: TextField(
              focusNode: widget.focusNode,
              controller: widget.controller,
              onChanged: widget.onChanged,
              style: const TextStyle(color: _onSurface, fontSize: 13.5),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: l10n.searchHint,
                hintStyle: const TextStyle(color: _onSurfaceVariant),
                contentPadding: const EdgeInsets.only(bottom: 2),
              ),
            ),
          ),
          if (_hasText)
            IconButton(
              icon: const Icon(LucideIcons.x,
                  size: 16, color: AppTheme.textTertiary),
              onPressed: () {
                widget.controller.clear();
                widget.onChanged('');
              },
            ),
        ],
      ),
    );
  }
}

/// 统一排序菜单。[labels] 按索引对应排序值（0 = 默认），两处调用方
/// 此前各内联一份 PopupMenuButton，字段渲染逻辑重复。
class SortMenu extends StatelessWidget {
  final int sort;
  final ValueChanged<int> onSort;
  final List<String> labels;

  const SortMenu({
    super.key,
    required this.sort,
    required this.onSort,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<int>(
      color: _surface,
      icon: const Icon(LucideIcons.arrowDownUp,
          size: 18, color: AppTheme.textTertiary),
      tooltip: l10n.tooltipSort,
      onSelected: onSort,
      itemBuilder: (c) => [
        for (var i = 0; i < labels.length; i++)
          PopupMenuItem(
            value: i,
            child: Text(labels[i],
                style: const TextStyle(color: _onSurface, fontSize: 13)),
          ),
      ],
    );
  }
}
