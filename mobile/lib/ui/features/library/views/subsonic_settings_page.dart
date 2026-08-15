import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/subsonic_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/library_provider.dart';

/// Subsonic / Navidrome / Jellyfin 音乐服务器配置页
class SubsonicSettingsPage extends ConsumerStatefulWidget {
  const SubsonicSettingsPage({super.key});

  @override
  ConsumerState<SubsonicSettingsPage> createState() =>
      _SubsonicSettingsPageState();
}

class _SubsonicSettingsPageState extends ConsumerState<SubsonicSettingsPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _testing = false;
  bool _saving = false;
  String _status = ''; // '' | 'ok' | 'fail' | 'empty'

  @override
  void initState() {
    super.initState();
    final prefs = PreferencesService.instance;
    _urlCtrl.text = prefs.subsonicBaseUrl ?? '';
    _userCtrl.text = prefs.subsonicUsername ?? '';
    _passCtrl.text = prefs.subsonicPassword;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    if (url.isEmpty || user.isEmpty) {
      setState(() => _status = 'empty');
      return;
    }
    setState(() {
      _testing = true;
      _status = '';
    });
    final ok = await SubsonicService.testConnection(
      baseUrl: url,
      username: user,
      password: pass,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _status = ok ? 'ok' : 'fail';
    });
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    if (url.isEmpty || user.isEmpty) {
      setState(() => _status = 'empty');
      return;
    }
    setState(() => _saving = true);
    await PreferencesService.instance.setSubsonicConfig(
      baseUrl: url,
      username: user,
      password: pass,
    );
    SubsonicService.configure(baseUrl: url, username: user, password: pass);
    if (!mounted) return;
    // 保存后立即扫描验证（复用 scanSubsonic 的合并/持久化，并把真实错误
    // 经 subsonicError 带出）。空库不是错误：扫描正常完成说明连接与凭据
    // 正确，照常保存返回；仅实际错误（subsonicError 非空）才留页回显。
    await ref.read(libraryProvider.notifier).scanSubsonic();
    if (!mounted) return;
    final hasError = ref.read(libraryProvider).subsonicError != null;
    setState(() {
      _saving = false;
      _status = hasError ? 'fail' : 'ok';
    });
    if (!hasError) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.subsonicTitle),
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
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
          children: [
            // ── 连接配置卡片 ──
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.highlight, width: 0.5),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    _Field(
                      icon: LucideIcons.cloud,
                      label: l10n.subsonicUrl,
                      hint: 'http://192.168.1.100:4533',
                      controller: _urlCtrl,
                      keyboardType: TextInputType.url,
                    ),
                    const Divider(height: 1, indent: 52),
                    _Field(
                      icon: LucideIcons.user,
                      label: l10n.subsonicUsername,
                      controller: _userCtrl,
                    ),
                    const Divider(height: 1, indent: 52),
                    _Field(
                      icon: LucideIcons.lock,
                      label: l10n.subsonicPassword,
                      controller: _passCtrl,
                      obscure: true,
                      textInputAction: TextInputAction.done,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.subsonicCompatible,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textTertiary.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.cloudCog, size: 18),
                    label: Text(l10n.nasTestConnection),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.surfaceDark,
                      foregroundColor: AppTheme.textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(LucideIcons.save, size: 18),
                    label: Text(l10n.nasSave),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _status == 'ok'
                    ? l10n.subsonicConnected
                    : _status == 'empty'
                    ? l10n.subsonicEnterUrl
                    : l10n.subsonicFailed,
                style: TextStyle(
                  color: _status == 'ok' ? AppTheme.success : AppTheme.danger,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 与 NAS 设置页同款列表项风格的表单字段。
/// 整行可点聚焦；[textInputAction] 控制回车行为（默认 next 依次跳转）。
class _Field extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;

  const _Field({
    required this.icon,
    required this.label,
    this.hint,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
  });

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  final _focusNode = FocusNode();
  bool _show = false;
  bool _hasText = false;

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
    final icon = widget.icon;
    final label = widget.label;
    final hint = widget.hint;
    final controller = widget.controller;
    final obscure = widget.obscure;
    final keyboardType = widget.keyboardType;
    final textInputAction = widget.textInputAction;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, color: AppTheme.textTertiary, size: 20),
      title: Text(
        label,
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      ),
      // 整行可点：聚焦到该输入框，避免精确点中才能聚焦
      onTap: () => FocusScope.of(context).requestFocus(_focusNode),
      subtitle: TextField(
        controller: controller,
        focusNode: _focusNode,
        obscureText: obscure && !_show,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontSize: 14,
            color: AppTheme.textTertiary,
          ),
          isDense: true,
          border: InputBorder.none,
          // 限定眼图标区域 24×24：不设的话默认 48×48（Material 最小
          // 交互尺寸），密码框会被撑得比其他输入框高、文本不再对齐
          suffixIconConstraints:
              const BoxConstraints.tightFor(width: 24, height: 24),
          suffixIcon: obscure
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
                      onPressed: () => controller.clear(),
                    )
                  : null,
        ),
      ),
    );
  }
}
