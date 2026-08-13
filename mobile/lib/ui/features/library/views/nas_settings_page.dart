import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/wl_toggle.dart';
import '../view_models/library_provider.dart';

/// NAS (SMB) 独立配置页面
///
/// 从导入 sheet 中独立出来，作为全屏页面使用，方便反复调整连接与测试。
class NasSettingsPage extends ConsumerStatefulWidget {
  const NasSettingsPage({super.key});

  @override
  ConsumerState<NasSettingsPage> createState() => _NasSettingsPageState();
}

class _NasSettingsPageState extends ConsumerState<NasSettingsPage> {
  final _hostCtrl = TextEditingController();
  final _shareCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _offlineCache = false;
  String? _nasType;
  bool _connecting = false;
  String _connectionStatus = '';

  @override
  void initState() {
    super.initState();
    final prefs = PreferencesService.instance;
    // 默认预填（仅当用户没保存过配置时）：本机 Mac 调试共享 music → /Users/qin/Public/music。
    // 用 qin 账户 + Mac 登录密码认证（密码不预填，需手输）。
    const testHost = '192.168.110.27';
    const testUser = 'qin';
    const testPass = '';
    const testShare = '/music';
    _hostCtrl.text = prefs.nasHost?.isNotEmpty == true
        ? prefs.nasHost!
        : testHost;
    _shareCtrl.text = prefs.nasShare?.isNotEmpty == true
        ? prefs.nasShare!
        : testShare;
    _userCtrl.text = prefs.nasUsername?.isNotEmpty == true
        ? prefs.nasUsername!
        : testUser;
    _passCtrl.text = prefs.nasPassword.isNotEmpty
        ? prefs.nasPassword
        : testPass;
    _nasType = prefs.nasType;
    _offlineCache = prefs.smbOfflineCache;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _shareCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _connecting = true;
      _connectionStatus = '';
    });

    final host = _hostCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    if (host.isEmpty) {
      setState(() {
        _connecting = false;
        _connectionStatus = 'host_empty';
      });
      return;
    }

    // Try SMB connection
    final ok = await SmbService.connect(
      host: host,
      username: user,
      password: pass,
    );

    if (!mounted) return;
    setState(() {
      _connecting = false;
      _connectionStatus = ok ? 'connected' : 'failed';
    });

    if (ok) {
      final shares = await SmbService.listShares();
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        // 先清掉可能堆积的旧 SnackBar，再显示新结果
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.nasShares(shares.join(', ')),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            backgroundColor: AccentScope.of(context),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      // 测试成功后不断开会话：保留给后续 SMB 播放直接用
      // （原来 disconnect 会销毁会话，导致之后所有 SMB 歌无法播放）
    } else if (mounted) {
      _showErrorSnackBar();
    }

    if (mounted) setState(() {});
  }

  /// 失败时展示具体错误，并带复制按钮方便反馈。
  /// 固定时长 + 先清队列，避免多次失败后 SnackBar 排队堆积"一直不消失"。
  void _showErrorSnackBar() {
    final l10n = AppLocalizations.of(context);
    final err = SmbService.lastError;
    final text = err == null
        ? l10n.nasConnectionFailedTitle
        : '$err\n\n${l10n.nasCheckHint}';
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, maxLines: 6, overflow: TextOverflow.ellipsis),
        backgroundColor: AppTheme.danger,
        duration: const Duration(seconds: 5),
        action: err == null
            ? null
            : SnackBarAction(
                label: l10n.nasCopy,
                textColor: Colors.white,
                onPressed: () => Clipboard.setData(ClipboardData(text: err)),
              ),
      ),
    );
  }

  /// 切换离线缓存：开启前弹确认，说明会占用大量本地空间。
  Future<void> _toggleOfflineCache() async {
    if (_offlineCache) {
      // 关闭：直接改
      setState(() => _offlineCache = false);
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(l10n.smbOfflineCacheTitle),
        content: Text(l10n.smbOfflineCacheMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.nasCancel,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.smbOfflineCacheConfirm,
              style: const TextStyle(color: AppTheme.accentFallback),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _offlineCache = true);
    }
  }

  Future<void> _saveAndConnect() async {
    await PreferencesService.instance.setNasConfig(
      type: _nasType,
      host: _hostCtrl.text.trim(),
      share: _shareCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
    );
    await PreferencesService.instance.setSmbOfflineCache(_offlineCache);

    // 触发后台导入（fire-and-forget，不阻塞页面）：
    // 立即返回曲库，导入进度在曲库页顶部展示，可随时取消。
    final host = _hostCtrl.text.trim();
    final share = _shareCtrl.text.trim();
    if (host.isNotEmpty && share.isNotEmpty) {
      ref.read(libraryProvider.notifier).startNasImport(share);
    }

    if (mounted) context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.nasTitle),
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
            // ── 连接配置（与设置页同款圆角卡片容器） ──
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    _NasField(
                      icon: LucideIcons.cloud,
                      label: l10n.nasHost,
                      hint: '192.168.110.27 or nas.local',
                      controller: _hostCtrl,
                    ),
                    const Divider(height: 1, indent: 16),
                    _NasField(
                      icon: LucideIcons.folder,
                      label: l10n.nasShare,
                      hint: '/Music or /public/music',
                      controller: _shareCtrl,
                    ),
                    const Divider(height: 1, indent: 16),
                    _NasField(
                      icon: LucideIcons.user,
                      label: l10n.nasUsername,
                      controller: _userCtrl,
                    ),
                    const Divider(height: 1, indent: 16),
                    _NasField(
                      icon: LucideIcons.lock,
                      label: l10n.nasPassword,
                      controller: _passCtrl,
                      obscure: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ── 离线缓存开关 ──
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(
                    LucideIcons.download,
                    color: AppTheme.textSecondary,
                    size: 22,
                  ),
                  title: Text(
                    l10n.smbOfflineCache,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    l10n.smbOfflineCacheHint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                  trailing: WlToggle(
                    value: _offlineCache,
                    onChanged: () => _toggleOfflineCache(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _connecting ? null : _testConnection,
                    icon: _connecting
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
                    onPressed: _connecting ? null : _saveAndConnect,
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
            if (_connectionStatus.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _connectionStatus == 'connected'
                    ? l10n.nasConnected
                    : _connectionStatus == 'host_empty'
                    ? l10n.nasEnterHost
                    : l10n.nasConnectionFailed,
                style: TextStyle(
                  color: _connectionStatus == 'connected'
                      ? AppTheme.success
                      : AppTheme.danger,
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

/// 设置页同款列表项风格的表单字段：左侧图标 + 标签 + 内联输入框
class _NasField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;

  const _NasField({
    required this.icon,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
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
          isDense: true,
          hintStyle: const TextStyle(
            fontSize: 14,
            color: AppTheme.textTertiary,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }
}
