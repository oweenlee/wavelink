import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../data/services/log.dart';
import '../../../../domain/models/nas_profile.dart';
import '../../../../domain/models/song.dart';
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
  final _portCtrl = TextEditingController();
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
    _portCtrl.text = '${prefs.nasPort}';
    _shareCtrl.text = prefs.nasShare ?? '';
    _userCtrl.text = prefs.nasUsername ?? '';
    _passCtrl.text = prefs.nasPassword;
    _nasType = prefs.nasType;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _shareCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// 执行 SMB 连接 + 共享名验证（与保存配置无关，读当前表单值）。
  /// 返回记录区分「服务器通」与「共享可读」：服务器通了但共享名错时
  /// 报 share_failed，避免误报"已连接"。
  Future<({bool ok, bool shareOk})> _attemptConnect() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 445;
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    final ok = await SmbService.connect(
      host: host,
      port: port,
      username: user,
      password: pass,
    );
    if (!ok) return (ok: false, shareOk: false);

    final shareParts = _shareCtrl.text
        .trim()
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final shareName = shareParts.isEmpty ? null : shareParts.first;
    final shareOk =
        shareName == null || await SmbService.connectShare(shareName);
    return (ok: true, shareOk: shareOk);
  }

  /// 验证连接（含 iOS 首次安装"本地网络"权限未授权时的自动重试：
  /// 系统在首次发起局域网连接时弹权限框，授权前点"测试连接"会被直接
  /// 阻断，第一次必然失败——提示用户点"允许"并延迟重试一次）。
  /// 返回服务器/共享验证结果；调用方负责 UI 状态与提示。
  Future<({bool ok, bool shareOk})> _verifyConnection() async {
    var result = await _attemptConnect();
    if (!result.ok && SmbService.isLocalNetworkBlocked) {
      if (!mounted) return result;
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
      if (!mounted) return result;
      result = await _attemptConnect();
    }
    return result;
  }

  Future<void> _testConnection() async {
    // 先收键盘，让按钮区恢复全高、测试结果可见
    FocusScope.of(context).unfocus();
    setState(() {
      _connecting = true;
      _connectionStatus = '';
    });

    if (_hostCtrl.text.trim().isEmpty) {
      setState(() {
        _connecting = false;
        _connectionStatus = 'host_empty';
      });
      return;
    }

    final result = await _verifyConnection();

    if (!mounted) return;
    setState(() {
      _connecting = false;
      _connectionStatus =
          result.ok && result.shareOk
              ? 'connected'
              : (result.ok ? 'share_failed' : 'failed');
    });

    if (result.ok && result.shareOk) {
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
    } else if (result.ok) {
      // 服务器通但共享名错：弹出详细错误（lastError = STATUS_BAD_NETWORK_NAME）
      _showErrorSnackBar();
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

  /// 检测到 NAS 连接目标（地址/端口/共享路径）变更且曲库已有旧 NAS 歌曲时，
  /// 弹出确认对话框：确认后清除旧 NAS 的曲库条目与下载缓存，避免更换服务器
  /// 后列表残留旧内容。仅改用户名/密码不算更换服务器，不弹窗。
  Future<bool> _confirmReplaceNas(int count) async {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          l10n.nasChangedTitle,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          l10n.nasChangedBody(count),
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.cancel,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.confirm,
              style: TextStyle(color: accent),
            ),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _saveAndConnect() async {
    if (_connecting) return; // 防重复点击
    FocusScope.of(context).unfocus();
    final l10n = AppLocalizations.of(context);
    final prefs = PreferencesService.instance;
    final newHost = _hostCtrl.text.trim();
    final newPort = int.tryParse(_portCtrl.text.trim()) ?? 445;
    final newShare = _shareCtrl.text.trim();

    if (newHost.isEmpty) {
      Fluttertoast.showToast(
        msg: l10n.nasEnterHost,
        gravity: ToastGravity.BOTTOM,
        fontSize: 13,
        backgroundColor: AppTheme.danger,
        textColor: AppTheme.textPrimary,
      );
      return;
    }

    // 保存前自动验证连接：失败即中止——不保存、不触发后台导入，
    // 避免配置错误时仍盲目导入、事后只能回头改。
    setState(() {
      _connecting = true;
      _connectionStatus = '';
    });
    final result = await _verifyConnection();
    if (!mounted) return;
    if (!result.ok || !result.shareOk) {
      setState(() {
        _connecting = false;
        _connectionStatus =
            result.ok ? 'share_failed' : 'failed';
      });
      _showErrorSnackBar();
      return;
    }
    setState(() {
      _connecting = false;
      _connectionStatus = '';
    });

    // 检测连接目标是否更换（首次配置不弹窗；仅改凭据不算更换）
    final oldHost = prefs.nasHost ?? '';
    final oldPort = prefs.nasPort;
    final oldShare = prefs.nasShare ?? '';
    final serverChanged = oldHost.isNotEmpty &&
        (newHost != oldHost || newPort != oldPort || newShare != oldShare);

    if (serverChanged) {
      final nasCount = ref
          .read(libraryProvider)
          .importedSongs
          .where((s) => s.source == SongSource.nas)
          .length;
      if (nasCount > 0) {
        final confirmed = await _confirmReplaceNas(nasCount);
        if (!confirmed || !mounted) {
          // 验证连接时（_verifyConnection 前置）已把全局会话切到新主机；
          // 用户取消替换时配置/曲库仍是旧主机，需断开会话，避免旧库播放
          // 走 ensureReady 时误在未确认的新主机上读文件（disconnect 有
          // _scanning 守护，扫描中会安全跳过）。
          await SmbService.disconnect();
          return;
        }
        // 清除旧 NAS 曲库条目与缓存（失败不阻断保存）
        try {
          await ref.read(libraryProvider.notifier).clearNasSongs();
        } catch (e) {
          Log.e('NAS', '清除旧 NAS 歌曲失败: $e');
        }
      }
    }

    await PreferencesService.instance.setNasConfig(
      type: _nasType,
      host: newHost,
      port: newPort,
      share: newShare,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
    );

    // 触发后台导入（fire-and-forget，不阻塞页面）：
    // 立即返回曲库，导入进度在曲库页顶部展示，可随时取消。
    if (newShare.isNotEmpty) {
      ref.read(libraryProvider.notifier).startNasImport(newShare);
    }

    if (!mounted) return;
    setState(() {}); // 刷新底部历史配置（新增/更新时间戳）
    Fluttertoast.showToast(
      msg: l10n.nasSaved,
      gravity: ToastGravity.BOTTOM,
      fontSize: 13,
      backgroundColor: AppTheme.ok,
      textColor: AppTheme.textPrimary,
    );
  }

  /// 点击底部已保存配置：填充上方输入框，并切换为该配置的数据源。
  /// 与当前激活配置不同时，确认后清除旧 NAS 歌曲并导入该配置。
  Future<void> _applyProfile(NasProfile p) async {
    final l10n = AppLocalizations.of(context);
    _hostCtrl.text = p.host;
    _portCtrl.text = '${p.port}';
    _shareCtrl.text = p.share;
    _userCtrl.text = p.username;
    _passCtrl.text = p.password;
    _nasType = p.type;
    setState(() {});

    final prefs = PreferencesService.instance;
    final active = prefs.activeNasProfile;
    final isActive = active != null && active.id == p.id;
    // 已是当前配置：仅填充表单，不切换
    if (isActive) return;

    final nasCount = ref
        .read(libraryProvider)
        .importedSongs
        .where((s) => s.source == SongSource.nas)
        .length;
    if (nasCount > 0) {
      final confirmed = await _confirmReplaceNas(nasCount);
      if (!confirmed || !mounted) return;
      try {
        await ref.read(libraryProvider.notifier).clearNasSongs();
      } catch (e) {
        Log.e('NAS', '切换清除旧 NAS 歌曲失败: $e');
      }
    }

    await prefs.setNasConfig(
      type: p.type,
      host: p.host,
      port: p.port,
      share: p.share,
      username: p.username,
      password: p.password,
    );
    if (p.share.isNotEmpty) {
      ref.read(libraryProvider.notifier).startNasImport(p.share);
    }
    if (!mounted) return;
    setState(() {});
    Fluttertoast.showToast(
      msg: l10n.nasSwitched(p.displayName),
      gravity: ToastGravity.BOTTOM,
      fontSize: 13,
      backgroundColor: AppTheme.ok,
      textColor: AppTheme.textPrimary,
    );
  }

  Future<bool> _confirmDeleteProfile({required bool isActive, required int count}) async {
    final l10n = AppLocalizations.of(context);
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          l10n.nasProfileDeleteTitle,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          isActive
              ? l10n.nasProfileDeleteBodyActive(count)
              : l10n.nasProfileDeleteBodyIdle,
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.cancel,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.delete,
              style: TextStyle(color: AppTheme.danger),
            ),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  /// 删除配置：同时清除其相关数据。删除的是「当前使用」配置时，
  /// 连同曲库中所有 NAS 歌曲与下载缓存一并清除，并清空激活字段。
  Future<void> _deleteProfile(NasProfile p) async {
    final prefs = PreferencesService.instance;
    final active = prefs.activeNasProfile;
    final isActive = active != null && active.id == p.id;
    final nasCount = ref
        .read(libraryProvider)
        .importedSongs
        .where((s) => s.source == SongSource.nas)
        .length;

    final confirmed = await _confirmDeleteProfile(
      isActive: isActive,
      count: nasCount,
    );
    if (!confirmed || !mounted) return;

    await prefs.removeNasProfile(p.id);
    if (isActive) {
      // 删除激活配置：清曲库 NAS 数据 + 激活字段 + 表单
      try {
        await ref.read(libraryProvider.notifier).clearNasSongs();
      } catch (e) {
        Log.e('NAS', '删除配置清除 NAS 歌曲失败: $e');
      }
      await prefs.clearNasConfig();
      _hostCtrl.clear();
      _portCtrl.text = '445';
      _shareCtrl.clear();
      _userCtrl.clear();
      _passCtrl.clear();
      _nasType = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final l10n = AppLocalizations.of(context);
    final profiles = PreferencesService.instance.nasProfiles;
    final activeNasId = PreferencesService.instance.activeNasProfile?.id;
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
                        icon: LucideIcons.network,
                        label: l10n.nasPort,
                        hint: '445',
                        controller: _portCtrl,
                        keyboardType: TextInputType.number,
                      ),
                      const Divider(height: 1, indent: 52),
                      ConfigField(
                        icon: LucideIcons.folder,
                        label: l10n.nasShare,
                        hint: 'Share name, e.g. Music or /public/music (no spaces)',
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
                    : _connectionStatus == 'share_failed'
                    ? l10n.nasShareInvalid
                    : l10n.nasConnectionFailed,
                style: TextStyle(
                  color: _connectionStatus == 'connected'
                      ? AppTheme.success
                      : AppTheme.danger,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 24),
            // ── 已保存的配置（点击填充输入框并切换数据源） ──
            Text(
              l10n.nasSavedProfiles,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            if (profiles.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.nasProfilesEmpty,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
              )
            else
              for (final p in profiles) ...[
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceDark,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: p.id == activeNasId
                          ? AppTheme.textSecondary
                          : AppTheme.highlight,
                      width: p.id == activeNasId ? 1.2 : 0.5,
                    ),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _applyProfile(p),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.server,
                              size: 18,
                              color: AppTheme.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          p.displayName,
                                          style: const TextStyle(
                                            color: AppTheme.textPrimary,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (p.id == activeNasId) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: accent,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            l10n.nasProfileActive,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${p.username.isEmpty ? '—' : p.username}'
                                    ' · :${p.port}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                LucideIcons.trash2,
                                size: 18,
                                color: AppTheme.danger,
                              ),
                              onPressed: () => _deleteProfile(p),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

/// 表单字段已抽为共享组件 ConfigField（lib/ui/core/widgets/config_field.dart），
/// NAS/Subsonic/WebDAV 三页共用，此处不再保留私有实现。
