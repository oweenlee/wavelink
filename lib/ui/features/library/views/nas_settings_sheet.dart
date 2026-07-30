import 'package:flutter/material.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../core/theme/app_theme.dart';

class NasSettingsSheet extends StatefulWidget {
  const NasSettingsSheet({super.key});

  @override
  State<NasSettingsSheet> createState() => _NasSettingsSheetState();
}

class _NasSettingsSheetState extends State<NasSettingsSheet> {
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
    _hostCtrl.text = prefs.nasHost ?? '';
    _shareCtrl.text = prefs.nasShare ?? '';
    _userCtrl.text = prefs.nasUsername ?? '';
    _passCtrl.text = prefs.nasPassword;
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
    }

    if (mounted) setState(() {});
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
      final ok = await SmbService.connect(
        host: _hostCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('NAS connected'),
            backgroundColor: AppTheme.brand,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('NAS connection failed'),
            backgroundColor: AppTheme.danger,
          ),
        );
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
                  Icons.close_rounded,
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
              Icons.cloud_off_rounded,
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
                prefixIcon: const Icon(Icons.cloud_rounded, size: 20),
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
                prefixIcon: const Icon(Icons.folder_rounded, size: 20),
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
                prefixIcon: const Icon(Icons.person_rounded, size: 20),
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
                prefixIcon: const Icon(Icons.lock_rounded, size: 20),
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
                        : const Icon(Icons.cloud_sync_rounded, size: 18),
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
                    icon: const Icon(Icons.save_rounded, size: 18),
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
