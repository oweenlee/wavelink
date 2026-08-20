import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/webdav_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/config_field.dart';
import '../view_models/library_provider.dart';

/// WebDAV 音乐服务器配置页（Nextcloud / Seafile / 群晖 WebDAV / 阿里云盘等）
class WebdavSettingsPage extends ConsumerStatefulWidget {
  const WebdavSettingsPage({super.key});

  @override
  ConsumerState<WebdavSettingsPage> createState() => _WebdavSettingsPageState();
}

class _WebdavSettingsPageState extends ConsumerState<WebdavSettingsPage> {
  final _urlCtrl = TextEditingController();
  final _pathCtrl = TextEditingController();
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
    _urlCtrl.text = prefs.webdavBaseUrl ?? '';
    _pathCtrl.text = prefs.webdavPath ?? '';
    _userCtrl.text = prefs.webdavUsername ?? '';
    _passCtrl.text = prefs.webdavPassword;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pathCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  String? _validate() {
    var url = _urlCtrl.text.trim();
    // 无 http(s):// 前缀时自动补 http:// 并写回输入框（局域网 WebDAV
    // 服务器多数为 http，免去手动补前缀；https-only 服务器用户改前缀即可）。
    // 补前缀后仍解析不出 host 才算格式错误。
    if (url.isEmpty) return 'empty';
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
    final error = await WebdavService.testConnection(
      baseUrl: _urlCtrl.text.trim(),
      path: _pathCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _status = error == null ? 'ok' : 'fail';
      _errorMsg = error ?? '';
    });
  }

  Future<void> _save() async {
    // 防重复点击：保存触发后台扫描（fire-and-forget），快速双击会并发
    // 起两个扫描共享同一 LibraryNotifier，onBatch 回调可能交叉写入。
    FocusScope.of(context).unfocus();
    if (_saving) return;
    _saving = true;
    try {
      final validation = _validate();
      if (validation != null) {
        setState(() => _status = validation);
        return;
      }
      await PreferencesService.instance.setWebdavConfig(
        baseUrl: _urlCtrl.text.trim(),
        path: _pathCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (!mounted) return;
      // 触发后台扫描（fire-and-forget，对齐 NAS 导入体验）：
      // 立即返回曲库，扫描进度经 onBatch 增量入库实时可见，
      // 真实错误经 webdavError 带出（曲库页顶部展示）。
      startWebdavScan(ref);
      if (mounted) context.pop(true);
    } finally {
      _saving = false;
    }
  }

  /// 后台启动 WebDAV 扫描（不阻塞调用方），错误经 [LibraryState.webdavError] 带出。
  static void startWebdavScan(WidgetRef ref) {
    final notifier = ref.read(libraryProvider.notifier);
    unawaited(notifier.scanWebdav());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.webdavTitle),
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
                        label: l10n.webdavUrl,
                        hint: 'http://192.168.1.100:5005',
                        controller: _urlCtrl,
                        keyboardType: TextInputType.url,
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.folderOpen,
                        label: l10n.webdavPath,
                        hint: '/music',
                        controller: _pathCtrl,
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.user,
                        label: l10n.webdavUsername,
                        controller: _userCtrl,
                        autofillHints: const [AutofillHints.username],
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.lock,
                        label: l10n.webdavPassword,
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
              l10n.webdavCompatible,
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
                    ? l10n.webdavEnterUrl
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
