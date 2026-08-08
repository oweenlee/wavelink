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
    setState(() => _saving = false);
    // 自动触发一次扫描（fire-and-forget，复用现有 scanSubsonic 合并/持久化）
    ref.read(libraryProvider.notifier).scanSubsonic();
    // 保存成功：返回上一页（抽屉/设置页）
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.subsonicTitle),
        backgroundColor: AppTheme.surfaceDark,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: AppTheme.textSecondary),
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
                color: AppTheme.surfaceDark.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
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

/// 与 NAS 设置页同款列表项风格的表单字段
class _Field extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;

  const _Field({
    required this.icon,
    required this.label,
    this.hint,
    required this.controller,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, color: AppTheme.textSecondary, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      ),
      subtitle: TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontSize: 14,
            color: AppTheme.textTertiary,
          ),
          isDense: true,
          border: InputBorder.none,
        ),
      ),
    );
  }
}
