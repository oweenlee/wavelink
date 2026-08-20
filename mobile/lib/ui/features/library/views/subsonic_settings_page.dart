import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/subsonic_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/config_field.dart';
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
  String _status = ''; // '' | 'ok' | 'fail' | 'empty' | 'invalid'
  String _errorMsg = ''; // 测试失败时的分类提示（服务层返回）

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

  /// URL 校验：无 http(s):// 前缀时自动补 http:// 并写回输入框。
  /// 局域网/自部署服务器多数为 http，免去手动补前缀（所见即所得，可改 https）；
  /// 补前缀后仍解析不出 host 才算格式错误。
  String? _validate() {
    var url = _urlCtrl.text.trim();
    if (url.isEmpty || _userCtrl.text.trim().isEmpty) return 'empty';
    if (!url.contains('://')) {
      final fixed = 'http://$url';
      _urlCtrl.value = TextEditingValue(
        text: fixed,
        selection: TextSelection.collapsed(offset: fixed.length),
      );
      url = fixed;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return 'invalid';
    return null;
  }

  Future<void> _test() async {
    // 先收键盘，让按钮区恢复全高、测试结果可见
    FocusScope.of(context).unfocus();
    final validation = _validate();
    if (validation != null) {
      setState(() => _status = validation);
      return;
    }
    setState(() {
      _testing = true;
      _status = '';
    });
    final error = await _verifyConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _status = error == null ? 'ok' : 'fail';
      _errorMsg = error ?? '';
    });
  }

  /// 验证连接（读当前表单值，与保存无关）。含 iOS 首次安装"本地网络"
  /// 权限未授权时的自动重试：仅填局域网 IP 时系统会在首次发起连接时弹
  /// 权限框，授权前会被直接阻断，第一次必然失败——提示用户点"允许"并
  /// 延迟重试一次。返回 null 表示成功，否则错误文案。
  Future<String?> _verifyConnection() async {
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    var error = await SubsonicService.testConnection(
      baseUrl: url,
      username: user,
      password: pass,
    );
    if (error != null && SubsonicService.isLocalNetworkBlocked) {
      if (!mounted) return error;
      final l10n = AppLocalizations.of(context);
      Fluttertoast.showToast(
        msg: l10n.nasLocalNetworkRetry,
        gravity: ToastGravity.BOTTOM,
        timeInSecForIosWeb: 3,
        fontSize: 13,
        backgroundColor: AppTheme.accentFallback,
        textColor: AppTheme.textPrimary,
      );
      // 留出权限弹窗的操作时间再重试
      await Future.delayed(const Duration(milliseconds: 2500));
      if (!mounted) return error;
      error = await SubsonicService.testConnection(
        baseUrl: url,
        username: user,
        password: pass,
      );
    }
    return error;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (_saving) return;
    final validation = _validate();
    if (validation != null) {
      setState(() => _status = validation);
      return;
    }
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    setState(() => _saving = true);
    // 保存前自动验证（含 iOS 本地网络权限重试）：连不通就不保存，
    // 避免保存了错误配置后扫描失败、用户以为已配好。
    final error = await _verifyConnection();
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _status = 'fail';
        _errorMsg = error;
      });
      return;
    }
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
                child: AutofillGroup(
                  child: Column(
                    children: [
                      ConfigField(
                        icon: LucideIcons.cloud,
                        label: l10n.subsonicUrl,
                        hint: 'http://192.168.1.100:4533',
                        controller: _urlCtrl,
                        keyboardType: TextInputType.url,
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.user,
                        label: l10n.subsonicUsername,
                        controller: _userCtrl,
                        autofillHints: const [AutofillHints.username],
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.lock,
                        label: l10n.subsonicPassword,
                        controller: _passCtrl,
                        obscure: true,
                        autofillHints: const [AutofillHints.password],
                      ),
                    ],
                  ),
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
                    : _status == 'invalid'
                    ? l10n.webdavInvalidUrl
                    : _errorMsg.isNotEmpty
                    ? _errorMsg
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

/// 表单字段已抽为共享组件 ConfigField（lib/ui/core/widgets/config_field.dart），
/// NAS/Subsonic/WebDAV 三页共用，此处不再保留私有实现。
