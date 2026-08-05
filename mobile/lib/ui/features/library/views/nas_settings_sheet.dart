import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../playback/view_models/playback_controller.dart';
import '../view_models/library_provider.dart';

class NasSettingsSheet extends ConsumerStatefulWidget {
  const NasSettingsSheet({super.key});

  @override
  ConsumerState<NasSettingsSheet> createState() => _NasSettingsSheetState();
}

class _NasSettingsSheetState extends ConsumerState<NasSettingsSheet> {
  final _hostCtrl = TextEditingController();
  final _shareCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _enabled = false;
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
    _hostCtrl.text = prefs.nasHost?.isNotEmpty == true ? prefs.nasHost! : testHost;
    _shareCtrl.text = prefs.nasShare?.isNotEmpty == true ? prefs.nasShare! : testShare;
    _userCtrl.text = prefs.nasUsername?.isNotEmpty == true ? prefs.nasUsername! : testUser;
    _passCtrl.text = prefs.nasPassword.isNotEmpty ? prefs.nasPassword : testPass;
    _enabled = prefs.nasEnabled;
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

    setState(() {
      _connecting = false;
      _connectionStatus = ok ? 'connected' : 'failed';
    });

    if (ok) {
      final shares = await SmbService.listShares();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Shares: ${shares.join(', ')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            backgroundColor: AppTheme.brand,
          ),
        );
      }
      await SmbService.disconnect();
    } else if (mounted) {
      _showErrorSnackBar();
    }

    if (mounted) setState(() {});
  }

  /// 失败时展示具体错误，并带复制按钮方便反馈
  void _showErrorSnackBar() {
    final err = SmbService.lastError;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err ?? 'NAS connection failed',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: AppTheme.danger,
        action: err == null
            ? null
            : SnackBarAction(
                label: 'Copy',
                textColor: Colors.white,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: err)),
              ),
      ),
    );
  }

  Future<void> _saveAndConnect() async {
    await PreferencesService.instance.setNasConfig(
      type: _nasType,
      host: _hostCtrl.text.trim(),
      share: _shareCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      enabled: _enabled,
    );

    // Connect to SMB if enabled
    if (_enabled && _hostCtrl.text.trim().isNotEmpty) {
      setState(() => _connecting = true);
      final ok = await SmbService.connect(
        host: _hostCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (!mounted) return;
      if (ok) {
        // 保存成功后自动扫描共享目录并导入曲库
        final share = _shareCtrl.text.trim();
        final before = ref.read(libraryProvider).importedSongs.length;
        final scanned = share.isEmpty
            ? false
            : await ref.read(playbackControllerProvider).scanSmb(share);
        final imported = ref.read(libraryProvider).importedSongs.length - before;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              scanned && imported > 0
                  ? 'NAS connected · imported $imported songs'
                  : scanned
                      ? 'NAS connected · no new audio found'
                      : 'NAS connected · empty share path, songs not imported',
            ),
            backgroundColor: AppTheme.brand,
          ),
        );
      } else if (mounted) {
        _showErrorSnackBar();
      }
    }

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'NAS Settings',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  LucideIcons.x,
                  color: AppTheme.textSecondary,
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text(
              'Enable NAS',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
            secondary: const Icon(
              LucideIcons.cloudOff,
              color: AppTheme.textSecondary,
            ),
            activeThumbColor: AppTheme.brand,
          ),
          if (_enabled) ...[
            TextField(
              controller: _hostCtrl,
              decoration: InputDecoration(
                labelText: 'Host',
                hintText: '192.168.1.100 or nas.local',
                prefixIcon: const Icon(LucideIcons.cloud, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: AppTheme.surfaceDark,
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _shareCtrl,
              decoration: InputDecoration(
                labelText: 'Share Path',
                hintText: '/Music or /public/music',
                prefixIcon: const Icon(LucideIcons.folder, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: AppTheme.surfaceDark,
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _userCtrl,
              decoration: InputDecoration(
                labelText: 'Username',
                prefixIcon: const Icon(LucideIcons.user, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: AppTheme.surfaceDark,
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(LucideIcons.lock, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: AppTheme.surfaceDark,
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 12),
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
                    label: const Text('Test Connection'),
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
                    onPressed: _saveAndConnect,
                    icon: const Icon(LucideIcons.save, size: 18),
                    label: const Text('Save'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
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
                    ? 'Connected'
                    : _connectionStatus == 'host_empty'
                    ? 'Enter host address'
                    : 'Connection failed',
                style: TextStyle(
                  color: _connectionStatus == 'connected'
                      ? AppTheme.success
                      : AppTheme.danger,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
