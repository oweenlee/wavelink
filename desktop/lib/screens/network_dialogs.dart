import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../models/track.dart';
import '../src/rust/api/smb.dart' as frb_smb;
import '../services/nas_service.dart';
import '../services/network_source_config.dart';
import '../services/player_controller.dart';
import '../services/subsonic_service.dart';
import '../services/webdav_service.dart';

/// 网络音源配置对话框（WebDAV / NAS / Subsonic）。
///
/// 单文件单组件，按 [source] 渲染不同字段；提供「测试连接」「保存」
/// 「扫描并导入到曲库」三步操作。配置经 [NetworkSourceConfig] 持久化，
/// 不落盘测试（NAS）走临时握手。样式沿用桌面端单色板（无彩色强调）。
class NetworkConfigDialog extends ConsumerStatefulWidget {
  final TrackSource source;
  final PlayerController player;
  const NetworkConfigDialog({
    super.key,
    required this.source,
    required this.player,
  });

  @override
  ConsumerState<NetworkConfigDialog> createState() =>
      _NetworkConfigDialogState();
}

class _NetworkConfigDialogState extends ConsumerState<NetworkConfigDialog> {
  final Map<String, TextEditingController> _c = {};
  bool _busy = false;
  String? _status; // null | 'ok:...' | 'err:...'
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final cfg = NetworkSourceConfig.instance;
    switch (widget.source) {
      case TrackSource.webdav:
        _init('baseUrl', cfg.webdavBaseUrl);
        _init('path', cfg.webdavPath);
        _init('username', cfg.webdavUsername);
        _init('password', cfg.webdavPassword);
      case TrackSource.nas:
        _init('host', cfg.nasHost);
        _init('port', cfg.nasPort.toString());
        _init('share', cfg.nasShare);
        _init('username', cfg.nasUsername);
        _init('password', cfg.nasPassword);
        _init('domain', cfg.nasDomain);
      case TrackSource.subsonic:
        _init('baseUrl', cfg.subsonicBaseUrl);
        _init('username', cfg.subsonicUsername);
        _init('password', cfg.subsonicPassword);
      case TrackSource.local:
        break;
    }
  }

  void _init(String k, String? v) =>
      _c[k] = TextEditingController(text: v ?? '');
  String _v(String k) => _c[k]?.text.trim() ?? '';

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    String? err;
    try {
      switch (widget.source) {
        case TrackSource.webdav:
          err = await WebdavService.testConnection(
            baseUrl: _v('baseUrl'),
            path: _v('path'),
            username: _v('username'),
            password: _v('password'),
          );
        case TrackSource.nas:
          err = await NasService.testConnection(
            host: _v('host'),
            port: int.tryParse(_v('port')) ?? 445,
            share: _v('share'),
            username: _v('username'),
            password: _v('password'),
            domain: _v('domain'),
          );
        case TrackSource.subsonic:
          err = await SubsonicService.testConnection(
            baseUrl: _v('baseUrl'),
            username: _v('username'),
            password: _v('password'),
          );
        case TrackSource.local:
          break;
      }
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = err == null ? 'ok:连接成功' : 'err:$err';
    });
  }

  Future<void> _save() async {
    final cfg = NetworkSourceConfig.instance;
    switch (widget.source) {
      case TrackSource.webdav:
        if (_v('baseUrl').isEmpty) {
          setState(() => _status = 'err:请填写服务器地址');
          return;
        }
        await cfg.setWebdavConfig(
          baseUrl: _v('baseUrl'),
          path: _v('path'),
          username: _v('username'),
          password: _v('password'),
        );
      case TrackSource.nas:
        if (_v('host').isEmpty || _v('share').isEmpty) {
          setState(() => _status = 'err:请填写主机与共享名');
          return;
        }
        await cfg.setNasConfig(
          host: _v('host'),
          port: int.tryParse(_v('port')) ?? 445,
          share: _v('share'),
          username: _v('username'),
          password: _v('password'),
          domain: _v('domain'),
        );
      case TrackSource.subsonic:
        if (_v('baseUrl').isEmpty || _v('username').isEmpty) {
          setState(() => _status = 'err:请填写服务器地址与用户名');
          return;
        }
        await cfg.setSubsonicConfig(
          baseUrl: _v('baseUrl'),
          username: _v('username'),
          password: _v('password'),
        );
      case TrackSource.local:
        break;
    }
    _saved = true;
    setState(() => _status = 'ok:已保存');
  }

  Future<void> _scan() async {
    if (!_saved) await _save();
    if (!_saved) return; // 校验未通过
    setState(() {
      _busy = true;
      _status = 'ok:正在扫描并导入…';
    });
    List<Track>? tracks;
    try {
      switch (widget.source) {
        case TrackSource.webdav:
          tracks = await widget.player.importWebdav();
        case TrackSource.nas:
          tracks = await widget.player.importNas();
        case TrackSource.subsonic:
          tracks = await widget.player.importSubsonic();
        case TrackSource.local:
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'err:扫描失败：$e';
      });
      return;
    }
    if (!mounted) return;
    // 扫描结果为空但有错误：显式提示，避免「已连接却列表空、无任何报错」。
    final err = NasService.lastError;
    if ((tracks?.isEmpty ?? true) && err != null) {
      setState(() {
        _busy = false;
        _status = 'err:扫描失败：$err';
      });
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, tracks?.length ?? 0);
  }

  /// NAS：列出服务器可用共享，供用户直接点选填入（避免盲填共享名导致扫不到）。
  Widget _sharesBrowser() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '不知道共享名？列出服务器上的可用共享',
              style: const TextStyle(color: kOnSurfaceVariant, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _browseShares,
            child: const Text('列出共享', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _browseShares() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    List<frb_smb.SmbShareInfo> shares;
    try {
      shares = await NasService.listSharesConnected(
        host: _v('host'),
        port: int.tryParse(_v('port')) ?? 445,
        username: _v('username'),
        password: _v('password'),
        domain: _v('domain'),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'err:无法列出共享：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (shares.isEmpty) {
      setState(() => _status = 'err:该服务器没有可用共享');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: kSurface,
        title: const Text('选择共享',
            style: TextStyle(color: kOnSurface, fontSize: 14)),
        children: shares
            .map(
              (s) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, s.name),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: const TextStyle(color: kOnSurface)),
                    if (s.comment.isNotEmpty)
                      Text(
                        s.comment,
                        style: const TextStyle(
                          color: kOnSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
    if (picked != null && mounted) {
      _c['share']!.text = picked;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.source) {
      TrackSource.webdav => 'WebDAV 服务器',
      TrackSource.nas => 'NAS (SMB)',
      TrackSource.subsonic => 'Subsonic 音乐服务器',
      TrackSource.local => '本地',
    };
    return AlertDialog(
      backgroundColor: kSurface,
      title: Text(title, style: const TextStyle(color: kOnSurface)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._fields(),
              if (widget.source == TrackSource.nas) _sharesBrowser(),
              if (_status != null) _statusLine(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: kOnSurfaceVariant)),
        ),
        TextButton(
          onPressed: _busy ? null : _test,
          child: const Text('测试连接', style: TextStyle(color: kOnSurface)),
        ),
        TextButton(
          onPressed: _busy ? null : _save,
          child: const Text('保存', style: TextStyle(color: kOnSurface)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: kOnSurface,
            foregroundColor: kSurface,
            disabledBackgroundColor: kSurface2,
          ),
          onPressed: _busy ? null : _scan,
          child: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: kSurface,
                  ),
                )
              : const Text('扫描并导入'),
        ),
      ],
    );
  }

  List<Widget> _fields() {
    final List<(String, String, bool, bool)> defs = switch (widget.source) {
      TrackSource.webdav => const [
          ('baseUrl', '服务器地址 (URL) *', false, true),
          ('path', '根目录 (可选)', false, false),
          ('username', '用户名 (可选)', false, false),
          ('password', '密码', true, false),
        ],
      TrackSource.nas => const [
          ('host', '主机 / IP *', false, true),
          ('port', '端口 (默认 445)', false, false),
          ('share', '共享名 *', false, true),
          ('username', '用户名 (可选)', false, false),
          ('password', '密码', true, false),
          ('domain', '域 (可选)', false, false),
        ],
      TrackSource.subsonic => const [
          ('baseUrl', '服务器地址 (URL) *', false, true),
          ('username', '用户名 *', false, true),
          ('password', '密码', true, false),
        ],
      TrackSource.local => const <(String, String, bool, bool)>[],
    };
    return defs
        .map(
          (d) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              controller: _c[d.$1],
              obscureText: d.$3,
              autofocus: d.$4,
              style: const TextStyle(color: kOnSurface, fontSize: 13.5),
              decoration: InputDecoration(
                labelText: d.$2,
                labelStyle:
                    const TextStyle(color: kOnSurfaceVariant, fontSize: 12),
                enabledBorder:
                    const OutlineInputBorder(borderSide: BorderSide(color: kBorder)),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: kOnSurfaceVariant),
                ),
              ),
            ),
          ),
        )
        .toList();
  }

  Widget _statusLine() {
    final ok = _status!.startsWith('ok:');
    final msg = _status!.substring(3);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            ok ? LucideIcons.circleCheck : LucideIcons.circleAlert,
            size: 15,
            color: ok ? kOnSurface : AppTheme.textTertiary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: ok ? kOnSurface : kOnSurfaceVariant,
                fontSize: 12,
                fontWeight: ok ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
