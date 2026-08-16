import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../l10n/app_localizations.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/config_field.dart';
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
  String? _nasType;
  bool _connecting = false;
  String _connectionStatus = '';

  @override
  void initState() {
    super.initState();
    final prefs = PreferencesService.instance;
    _hostCtrl.text = prefs.nasHost ?? '';
    _shareCtrl.text = prefs.nasShare ?? '';
    _userCtrl.text = prefs.nasUsername ?? '';
    _passCtrl.text = prefs.nasPassword;
    _nasType = prefs.nasType;
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
    // 先收键盘，让按钮区恢复全高、测试结果可见
    FocusScope.of(context).unfocus();
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
        Fluttertoast.showToast(
          msg: l10n.nasShares(shares.join(', ')),
          gravity: ToastGravity.BOTTOM,
          timeInSecForIosWeb: 4,
          fontSize: 13,
          backgroundColor: AppTheme.ok,
          textColor: AppTheme.textPrimary,
        );
      }
      // 测试成功后不断开会话：保留给后续 SMB 播放直接用
      // （原来 disconnect 会销毁会话，导致之后所有 SMB 歌无法播放）
    } else if (mounted) {
      _showErrorSnackBar();
    }

    if (mounted) setState(() {});
  }

  /// 失败时展示具体错误信息。
  /// 有详细错误（含 SMB 协议栈 dump，可能很长）时弹 dialog：文案可选中、
  /// 可复制，方便贴给开发者排查；toast 2 秒消失不可选中，只用于无错误
  /// 场景的兜底提示。
  void _showErrorSnackBar() {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    final err = SmbService.lastError;
    if (err == null) {
      Fluttertoast.showToast(
        msg: l10n.nasConnectionFailedTitle,
        gravity: ToastGravity.BOTTOM,
        timeInSecForIosWeb: 2,
        fontSize: 13,
        backgroundColor: AppTheme.danger,
        textColor: AppTheme.textPrimary,
      );
      return;
    }
    final detail = '$err\n\n${l10n.nasCheckHint}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          l10n.nasConnectionFailedTitle,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            detail,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: detail));
              Navigator.pop(ctx);
            },
            child: Text(
              l10n.nasCopy,
              style: TextStyle(color: accent),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              l10n.confirm,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndConnect() async {
    FocusScope.of(context).unfocus();
    await PreferencesService.instance.setNasConfig(
      type: _nasType,
      host: _hostCtrl.text.trim(),
      share: _shareCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
    );

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
            // ── 连接配置（与设置页同款圆角卡片容器） ──
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
                        label: l10n.nasHost,
                        hint: '192.168.110.27 or nas.local',
                        controller: _hostCtrl,
                        keyboardType: TextInputType.url,
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.folder,
                        label: l10n.nasShare,
                        hint: '/Music or /public/music',
                        controller: _shareCtrl,
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.user,
                        label: l10n.nasUsername,
                        controller: _userCtrl,
                        autofillHints: const [AutofillHints.username],
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.lock,
                        label: l10n.nasPassword,
                        controller: _passCtrl,
                        obscure: true,
                        autofillHints: const [AutofillHints.password],
                      ),
                    ],
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

/// 表单字段已抽为共享组件 ConfigField（lib/ui/core/widgets/config_field.dart），
/// NAS/Subsonic/WebDAV 三页共用，此处不再保留私有实现。
