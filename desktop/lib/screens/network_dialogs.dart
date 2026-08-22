import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../src/rust/api/smb.dart' as frb_smb;
import '../services/nas_service.dart';
import '../services/network_source_config.dart';
import '../services/player_notifier.dart';
import '../services/subsonic_service.dart';
import '../services/webdav_service.dart';

/// 网络音源配置对话框（WebDAV / NAS / Subsonic）。
///
/// 单文件单组件，按 [source] 渲染不同字段；提供「测试连接」(可选)
/// 与「保存并导入到曲库」两步操作。配置经 [NetworkSourceConfig] 持久化，
/// 不落盘测试（NAS）走临时握手。样式沿用桌面端单色板（无彩色强调）。
class NetworkConfigDialog extends ConsumerStatefulWidget {
  final TrackSource source;
  final PlayerNotifier player;
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
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = false;
      _status = err == null ? 'ok:${l10n.connOk}' : 'err:$err';
    });
  }

  Future<void> _save() async {
    final cfg = NetworkSourceConfig.instance;
    final l10n = AppLocalizations.of(context);
    switch (widget.source) {
      case TrackSource.webdav:
        if (_v('baseUrl').isEmpty) {
          setState(() => _status = 'err:${l10n.fillServerUrl}');
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
          setState(() => _status = 'err:${l10n.fillHostShare}');
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
          setState(() => _status = 'err:${l10n.fillServerUser}');
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
    setState(() => _status = 'ok:${l10n.saved}');
  }

  Future<void> _saveAndImport() async {
    final l10n = AppLocalizations.of(context);
    if (!_saved) await _save();
    if (!_saved) return; // 校验未通过
    setState(() {
      _busy = true;
      _status = 'ok:${l10n.scanningImporting}';
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
        _status = 'err:${l10n.scanFailed(e)}';
      });
      return;
    }
    if (!mounted) return;
    // 扫描结果为空但有错误：显式提示，避免「已连接却列表空、无任何报错」。
    // 注意按音源读对应服务的 lastError（曾统一读 NasService.lastError，
    // webdav/subsonic 出错时永远取不到值）。
    final err = switch (widget.source) {
      TrackSource.webdav => WebdavService.lastError,
      TrackSource.nas => NasService.lastError,
      TrackSource.subsonic => SubsonicService.lastError,
      TrackSource.local => null,
    };
    if ((tracks?.isEmpty ?? true) && err != null) {
      setState(() {
        _busy = false;
        _status = 'err:${l10n.scanFailed(err)}';
      });
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, tracks?.length ?? 0);
  }

  /// NAS：列出服务器可用共享，供用户直接点选填入（避免盲填共享名导致扫不到）。
  Widget _sharesBrowser() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.unknownShareHint,
              style: const TextStyle(color: kOnSurfaceVariant, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _browseShares,
            child: Text(l10n.listShares, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _browseShares() async {
    final l10n = AppLocalizations.of(context);
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
        _status = 'err:${l10n.cannotListShares(e)}';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (shares.isEmpty) {
      setState(() => _status = 'err:${l10n.noSharesOnServer}');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: kSurface,
        title: Text(l10n.pickShare,
            style: const TextStyle(color: kOnSurface, fontSize: 14)),
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
    final l10n = AppLocalizations.of(context);
    final title = switch (widget.source) {
      TrackSource.webdav => l10n.dlgTitleWebdav,
      TrackSource.nas => l10n.dlgTitleNas,
      TrackSource.subsonic => l10n.dlgTitleSubsonic,
      TrackSource.local => l10n.dlgTitleLocal,
    };
    return AlertDialog(
      backgroundColor: kSurface,
      title: Text(title,
          style: const TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: kOnSurface,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child:           Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._fields(),
              if (widget.source == TrackSource.subsonic)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Text(
                    l10n.dlgSubsonicCompatHint,
                    style: const TextStyle(
                        color: AppTheme.textTertiary, fontSize: 11.5),
                  ),
                ),
              if (widget.source == TrackSource.nas) _sharesBrowser(),
              if (_status != null) _statusLine(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.btnCancel,
              style: const TextStyle(color: kOnSurfaceVariant)),
        ),
        TextButton(
          onPressed: _busy ? null : _test,
          child: Text(l10n.btnTest, style: const TextStyle(color: kOnSurface)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: kOnSurface,
            foregroundColor: kSurface,
            disabledBackgroundColor: kSurface2,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _busy ? null : _saveAndImport,
          child: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: kSurface,
                  ),
                )
              : Text(l10n.btnSaveImport),
        ),
      ],
    );
  }

  List<Widget> _fields() {
    final l10n = AppLocalizations.of(context);
    final defs = switch (widget.source) {
      TrackSource.webdav => <(String, String, bool, bool)>[
          ('baseUrl', l10n.fieldServerUrl, false, true),
          ('path', l10n.fieldPath, false, false),
          ('username', l10n.fieldUsernameOpt, false, false),
          ('password', l10n.fieldPassword, true, false),
        ],
      TrackSource.nas => <(String, String, bool, bool)>[
          ('host', l10n.fieldHost, false, true),
          ('port', l10n.fieldPort, false, false),
          ('share', l10n.fieldShare, false, true),
          ('username', l10n.fieldUsernameOpt, false, false),
          ('password', l10n.fieldPassword, true, false),
          ('domain', l10n.fieldDomain, false, false),
        ],
      TrackSource.subsonic => <(String, String, bool, bool)>[
          ('baseUrl', l10n.fieldServerUrl, false, true),
          ('username', l10n.fieldUsernameReq, false, true),
          ('password', l10n.fieldPassword, true, false),
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
                isDense: true,
                filled: true,
                fillColor: AppTheme.s3,
                // 垂直 13：13*2 + 行高16 + 边框2 ≈ 44px 输入框总高
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.highlightStrong),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                      color: AppTheme.textTertiary, width: 1.4),
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
    final color = ok ? AppTheme.ok : AppTheme.danger;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: color.withAlpha(0x0D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withAlpha(0x40)),
        ),
        child: Row(
          children: [
            Icon(
              ok ? LucideIcons.circleCheck : LucideIcons.circleAlert,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                msg,
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: ok ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
