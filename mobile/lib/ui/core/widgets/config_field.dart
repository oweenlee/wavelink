import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme/app_theme.dart';

/// 音源配置页（NAS / Subsonic / WebDAV）共用的表单字段。
///
/// 列表项风格：左侧图标 + 标签 + 内联输入框，整行可点聚焦。
/// - 密码框（[obscure]）内置小眼睛切换明文；
/// - 聚焦且非空时显示清空 X；
/// - [autofillHints] 非空时接入系统自动填充（用户名/密码），
///   同时自动打开 `enableSuggestions`（autofill 的前置要求），
///   其余字段保持关闭避免地址框弹无关建议；
/// - [textCapitalization] 恒为 none：服务器地址/路径/用户名大小写敏感，
///   iOS 默认会把首字母大写，会造成"输对却连不上"；
/// - 回车行为交给 Flutter 默认：非末字段 `textInputAction: next`
///   自动跳转下一可聚焦组件，密码框 `done` 默认收键盘。
class ConfigField extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final Iterable<String>? autofillHints;

  const ConfigField({
    super.key,
    required this.icon,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.autofillHints,
  });

  @override
  State<ConfigField> createState() => _ConfigFieldState();
}

class _ConfigFieldState extends State<ConfigField> {
  bool _show = false;
  bool _hasText = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onCtrlChanged);
    // 聚焦状态变化时刷新 × 显隐（仅在焦点内显示清除按钮）
    _focusNode.addListener(_onFocusChanged);
  }

  void _onCtrlChanged() {
    final has = widget.controller.text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onCtrlChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(widget.icon, color: AppTheme.textTertiary, size: 20),
      title: Text(
        widget.label,
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      ),
      // 整行可点：聚焦到该输入框，避免精确点中才能聚焦
      onTap: () => FocusScope.of(context).requestFocus(_focusNode),
      subtitle: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        obscureText: widget.obscure && !_show,
        textCapitalization: TextCapitalization.none,
        autocorrect: false,
        // 系统自动填充要求 enableSuggestions=true；其余字段保持关闭
        enableSuggestions: widget.autofillHints != null,
        autofillHints: widget.autofillHints,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: widget.hint,
          isDense: true,
          // 限定眼图标区域 24×24：不设的话默认 48×48（Material 最小
          // 交互尺寸），密码框会被撑得比其他输入框高、文本不再对齐
          suffixIconConstraints:
              const BoxConstraints.tightFor(width: 24, height: 24),
          hintStyle: const TextStyle(
            fontSize: 14,
            color: AppTheme.textTertiary,
          ),
          border: InputBorder.none,
          suffixIcon: widget.obscure
              ? IconButton(
                  icon: Icon(
                    _show ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                  // 缩掉 48×48 默认点击热区：否则密码框比
                  // 普通输入框高出一截（IconButton tap target 撑高）
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() => _show = !_show),
                )
              : _hasText && _focusNode.hasFocus
                  ? IconButton(
                      icon: const Icon(
                        LucideIcons.x,
                        size: 18,
                        color: AppTheme.textSecondary,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: '清除',
                      onPressed: () => widget.controller.clear(),
                    )
                  : null,
        ),
      ),
    );
  }
}
