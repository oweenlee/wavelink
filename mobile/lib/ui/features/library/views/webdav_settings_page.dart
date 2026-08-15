import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/webdav_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
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
  String _status = ''; // '' | 'ok' | 'fail' | 'empty'

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
    final url = _urlCtrl.text.trim();
    // 校验 URL 格式：需含 http(s):// 前缀，否则 Uri 解析后 host 为空，
    // 请求会全部异常。WebDAV 用户名/密码/路径均可选（支持匿名访问）。
    if (url.isEmpty) return 'empty';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return 'invalid';
    return null;
  }

  Future<void> _test() async {
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
    });
  }

  Future<void> _save() async {
    // 防重复点击：保存触发后台扫描（fire-and-forget），快速双击会并发
    // 起两个扫描共享同一 LibraryNotifier，onBatch 回调可能交叉写入。
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
                child: Column(
                  children: [
                    _Field(
                      icon: LucideIcons.cloud,
                      label: l10n.webdavUrl,
                      hint: 'http://192.168.1.100:5005',
                      controller: _urlCtrl,
                      keyboardType: TextInputType.url,
                    ),
                    const Divider(height: 1, indent: 52),
                    _Field(
                      icon: LucideIcons.folderOpen,
                      label: l10n.webdavPath,
                      hint: '/music',
                      controller: _pathCtrl,
                    ),
                    const Divider(height: 1, indent: 52),
                    _Field(
                      icon: LucideIcons.user,
                      label: l10n.webdavUsername,
                      controller: _userCtrl,
                    ),
                    const Divider(height: 1, indent: 52),
                    _Field(
                      icon: LucideIcons.lock,
                      label: l10n.webdavPassword,
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

/// 与 NAS/Subsonic 设置页同款列表项风格的表单字段。
/// [obscure] 为 true（密码框）时内置小眼睛，可切换明文显示。
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: widget.hint,
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
