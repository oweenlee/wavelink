import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import 'wl_slider.dart';

// ═══════════════════════════ 设置页控件基元 ═══════════════════════════
//
// 自 screens/settings.dart 迁出的 State 方法级控件基元（对齐 mobile
// `ui/core/widgets/`「控件单源」的组织方式）：下拉框 / 滑块行 / 开关 /
// 输入框 / 主按钮 / 指标卡 / 读数 chip / AutoEQ tile。
// 所有 Key 透传，供 widget 测试定位。

/// 技术读数 chip（等宽字体 label + value）。
class TechChip extends StatelessWidget {
  final String label;
  final String value;
  const TechChip({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.s3,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppTheme.highlightStrong),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
                text: '$label ',
                style: WlText.mono(color: AppTheme.textTertiary, fontSize: 10)),
            TextSpan(
                text: value,
                style: WlText.mono(color: AppTheme.textPrimary, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

/// [TechChip] 的流式容器。
class TechChips extends StatelessWidget {
  final List<Widget> children;
  const TechChips({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }
}

/// 统一输入框（SettingTile.child 用）。
class SettingTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final Color? accent;
  const SettingTextField({
    super.key,
    this.controller,
    this.hint,
    this.onChanged,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppTheme.textTertiary, fontSize: 13),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        filled: true,
        fillColor: AppTheme.s3,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppTheme.highlightStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              BorderSide(color: accent ?? AppTheme.textTertiary, width: 1.4),
        ),
      ),
    );
  }
}

/// 统一下拉框。
///
/// 值不在候选项时回退 null（显示 hint），避免 DropdownButton 构建期抛
/// "exactly one item with value" 断言（设备拔出 / prefs 残留旧值等场景）。
class SettingDropdown<T> extends StatelessWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? hint;
  final double width;
  const SettingDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) {
    final T? safeValue = (value != null && items.any((i) => i.value == value))
        ? value
        : null;
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.s3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: DropdownButton<T>(
          value: safeValue,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          icon: const Icon(LucideIcons.chevronDown,
              size: 16, color: AppTheme.textSecondary),
          hint: hint != null
              ? Text(hint!,
                  style: const TextStyle(
                      color: AppTheme.textTertiary, fontSize: 13))
              : null,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 带等宽读数的滑块行（SettingTile.child 用）。
class SliderWithLabel extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) fmt;
  final ValueChanged<double> onChanged;
  const SliderWithLabel({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.fmt,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: wlSliderTheme(
              color: AppTheme.textPrimary,
              inactiveColor: AppTheme.s4,
              overlayRadius: 14,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 72,
          child: Text(fmt(value),
              textAlign: TextAlign.end,
              style: WlText.mono(color: AppTheme.textSecondary, fontSize: 12)),
        ),
      ],
    );
  }
}

/// 强调色 Switch（与全局 AccentScope 协调）。
class AccentSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const AccentSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      activeThumbColor: accent.withAlpha(255),
      activeTrackColor: accent.withAlpha(0x30),
      inactiveThumbColor: AppTheme.textTertiary,
      inactiveTrackColor: AppTheme.s3,
    );
  }
}

/// 实心主按钮（前景色随底色亮度自适应）。
class SettingPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final Color? accent;
  const SettingPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppTheme.textPrimary;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor:
            color.computeLuminance() > 0.45 ? AppTheme.background : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

/// 诊断指标卡。
class MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  const MetricCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.s2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: (valueColor ?? AppTheme.textTertiary).withAlpha(0x14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon,
                      size: 16, color: valueColor ?? AppTheme.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(value,
                style: WlText.mono(
                    fontSize: 18,
                    color: valueColor ?? AppTheme.textPrimary,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// AutoEQ 型号选择对话框的单行 tile。
class AutoEqTile extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  const AutoEqTile({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? accent.withAlpha(0x12) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: selected
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400)),
              ),
              if (selected) Icon(LucideIcons.check, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}
