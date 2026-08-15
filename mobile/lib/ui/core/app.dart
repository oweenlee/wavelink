import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;
import '../../l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'theme/app_theme.dart';
import '../../data/services/preferences_service.dart';
import '../../data/services/smb_service.dart';
import '../../data/services/subsonic_service.dart';
import '../../data/services/webdav_service.dart';
import '../features/settings/view_models/locale_provider.dart';
import '../features/library/view_models/library_header_notifier.dart';
import '../features/library/view_models/library_provider.dart';
import '../features/playback/view_models/playback_controller.dart';
import 'widgets/mini_player_bar.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'routes.dart';

class WaveLinkApp extends ConsumerWidget {
  const WaveLinkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(localeProvider);
    final deviceLocale = PlatformDispatcher.instance.locale;
    final locale = LocaleNotifier.resolve(mode, deviceLocale);
    return MaterialApp.router(
      title: 'WaveLink',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme.copyWith(
        splashFactory: Platform.isIOS
            ? NoSplash.splashFactory
            : InkSparkle.splashFactory,
        highlightColor: Platform.isIOS ? Color(0x08FFFFFF) : null,
      ),
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleNotifier.supported,
      routerConfig: goRouter,
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;

  const AppShell({super.key, required this.navigationShell});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  DateTime? _lastLibraryTap;

  /// 双击曲库 tab：第一次正常切页，350ms 内第二次打开抽屉
  void _onLibraryTap() {
    final now = DateTime.now();
    if (_lastLibraryTap != null &&
        now.difference(_lastLibraryTap!) < const Duration(milliseconds: 350)) {
      _lastLibraryTap = null;
      _scaffoldKey.currentState?.openDrawer();
    } else {
      _lastLibraryTap = now;
      _goTab(0);
    }
  }

  /// 抽屉打开（双击/左滑手势/边缘滑动均触发）：轻震动反馈
  void _onDrawerChanged(bool opened) {
    if (opened) HapticFeedback.lightImpact();
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppTheme.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currentTab = widget.navigationShell.currentIndex;
    final headerState = ref.watch(libraryHeaderProvider);

    // 根壳拦截系统返回（Android 左边缘右滑=系统返回手势）：
    // 根页面无返回栈，返回键/左滑 → 开/关抽屉，避免误退 app 回桌面。
    // 子路由（专辑/设置详情等）的返回手势不受影响。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final scaffold = _scaffoldKey.currentState;
        if (scaffold == null) return;
        if (scaffold.isDrawerOpen) {
          scaffold.closeDrawer();
        } else {
          scaffold.openDrawer();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: const _QuickDrawer(),
        onDrawerChanged: _onDrawerChanged,
        backgroundColor: AppTheme.background,
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    if (currentTab == 0)
                      // 曲库页：Space Grotesk 字标 + 操作图标
                      const Text(
                        'WAVELINK',
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.18 * 22,
                          color: AppTheme.textPrimary,
                        ),
                      )
                    else
                      Text(
                        _getTitle(currentTab, l10n),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    const Spacer(),
                    if (currentTab == 0) ...[
                      // 搜索开关
                      _HeaderIconButton(
                        icon: LucideIcons.search,
                        onTap: () => ref
                            .read(libraryHeaderProvider.notifier)
                            .toggleSearch(),
                        active: headerState.isSearchVisible,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(child: widget.navigationShell),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiniPlayerBar(onTap: () => context.push('/now-playing')),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.background,
                border: Border(
                  top: BorderSide(
                    color: AppTheme.textTertiary.withValues(alpha: 0.1),
                    width: 0.5,
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _NavItem(
                        icon: LucideIcons.library,
                        label: l10n.tabLibrary,
                        isSelected: currentTab == 0,
                        onTap: _onLibraryTap,
                      ),
                      _NavItem(
                        icon: LucideIcons.slidersHorizontal,
                        label: l10n.tabPlay,
                        isSelected: false,
                        onTap: () => context.push('/now-playing'),
                      ),
                      _NavItem(
                        icon: LucideIcons.settings,
                        label: l10n.tabSettings,
                        isSelected: currentTab == 1,
                        onTap: () => _goTab(1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goTab(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  String _getTitle(int tab, AppLocalizations l10n) {
    switch (tab) {
      case 0:
        return l10n.titleLibrary;
      case 1:
        return l10n.titleSettings;
      default:
        return '';
    }
  }
}

/// 曲库快捷抽屉（双击底部「曲库」tab 打开）：导入音乐功能菜单
class _QuickDrawer extends ConsumerStatefulWidget {
  const _QuickDrawer();

  @override
  ConsumerState<_QuickDrawer> createState() => _QuickDrawerState();
}

class _QuickDrawerState extends ConsumerState<_QuickDrawer> {
  bool _discovering = false;
  bool _subsonicScanning = false;
  String? _subsonicResult;
  bool _webdavScanning = false;
  String? _webdavResult;

  Future<void> _handleDiscover() async {
    if (_discovering) return;
    final player = ref.read(playbackControllerProvider);
    setState(() => _discovering = true);
    await player.discoverSongs();
    if (!mounted) return;
    // 扫描完成即回到开关态（不显示结果文案）
    setState(() => _discovering = false);
  }

  Future<void> _handlePickFiles() async {
    final player = ref.read(playbackControllerProvider);
    Navigator.of(context).pop(); // 关抽屉（系统文件选择器会盖住）
    final count = await player.importFromPicker();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (count > 0) {
      Fluttertoast.showToast(
        msg: l10n.importN(count),
        gravity: ToastGravity.BOTTOM,
        fontSize: 13,
        backgroundColor: AppTheme.ok,
        textColor: AppTheme.textPrimary,
      );
    }
  }

  void _handleNas() {
    Navigator.of(context).pop(); // 关抽屉
    context.push('/nas');
  }

  /// Subsonic：与 NAS 共享一致——点击行进配置页（可测试/修改/重新连接），
  /// 重新扫描改由右侧同步按钮触发（仅已配置时显示）。
  void _handleSubsonic() {
    Navigator.of(context).pop(); // 关抽屉
    context.push('/subsonic');
  }

  Future<void> _scanSubsonic() async {
    if (_subsonicScanning) return;
    final player = ref.read(playbackControllerProvider);
    setState(() {
      _subsonicScanning = true;
      _subsonicResult = null;
    });
    final ok = await player.scanSubsonic();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    // 扫描失败但非空库：优先显示具体错误（网络/凭据等），
    // 区别于「服务器确实无歌曲」的空库场景
    final error = ref.read(libraryProvider).subsonicError;
    setState(() {
      _subsonicScanning = false;
      _subsonicResult = ok
          ? l10n.sourceFound
          : error != null
          ? l10n.subsonicFailed
          : l10n.sourceNotFound;
    });
  }

  /// WebDAV：与 NAS 共享一致——点击行进配置页（可测试/修改/重新连接），
  /// 重新扫描改由右侧同步按钮触发（仅已配置时显示）。
  void _handleWebdav() {
    Navigator.of(context).pop(); // 关抽屉
    context.push('/webdav');
  }

  Future<void> _scanWebdav() async {
    if (_webdavScanning) return;
    final player = ref.read(playbackControllerProvider);
    setState(() {
      _webdavScanning = true;
      _webdavResult = null;
    });
    final ok = await player.scanWebdav();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final error = ref.read(libraryProvider).webdavError;
    setState(() {
      _webdavScanning = false;
      _webdavResult = ok
          ? l10n.sourceFound
          : error != null
          ? l10n.subsonicFailed
          : l10n.sourceNotFound;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Drawer(
      backgroundColor: AppTheme.surfaceDark,
      width: 280,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题区
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'WAVELINK',
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.18 * 22,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.drawerSubtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Divider(
              height: 1,
              color: AppTheme.textTertiary.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 4),
            // 音源管理：一行 = 一个音源（点击行=添加/扫描/管理，左侧点=连接状态）
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                l10n.sourcesSection,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: AppTheme.textTertiary,
                ),
              ),
            ),
            // 系统音乐库（iOS=Apple Music / Android=设备音乐库）
            _SourceRow(
              icon: Platform.isIOS ? LucideIcons.apple : LucideIcons.smartphone,
              label: Platform.isIOS
                  ? l10n.sourceAppleMusic
                  : l10n.sourceDeviceLibrary,
              subtitle: Platform.isIOS
                  ? l10n.sourceAppleMusicHint
                  : l10n.sourceDeviceLibraryHint,
              connected: true,
              loading: _discovering,
              onTap: _handleDiscover,
            ),
            // 文件导入
            _SourceRow(
              icon: LucideIcons.folderOpen,
              label: l10n.sourceFileImport,
              subtitle: l10n.sourceFileImportHint,
              connected: true,
              onTap: _handlePickFiles,
            ),
            // NAS：已连接时右侧显示同步按钮，点击重新扫描 NAS 合并曲库
            _SourceRow(
              icon: LucideIcons.hardDrive,
              label: l10n.sourceNas,
              subtitle: SmbService.isConnected
                  ? l10n.sourceNasConnected
                  : l10n.sourceNasHint,
              connected: SmbService.isConnected,
              onTap: _handleNas,
              trailing: SmbService.isConnected
                  ? _NasSyncButton(
                      // select 只盯同步标志：NAS 导入逐批入库时曲库 state 高频变化，
                      // watch 整个 state 会让 app 壳（含当前页）跟着每批重建
                      syncing: ref.watch(
                        libraryProvider.select((s) => s.nasImporting),
                      ),
                    )
                  : null,
            ),
            // 音乐服务器（Subsonic 兼容）：已配置时行尾提供重新扫描按钮，
            // 点击行仍进配置页（与 NAS 共享一致的管理方式）
            _SourceRow(
              icon: LucideIcons.server,
              label: l10n.sourceMusicServer,
              subtitle: SubsonicService.isConfigured
                  ? l10n.sourceMusicServerConnected
                  : l10n.sourceMusicServerHint,
              connected: SubsonicService.isConfigured,
              loading: _subsonicScanning,
              result: _subsonicResult,
              onTap: _handleSubsonic,
              trailing: SubsonicService.isConfigured
                  ? _ScanButton(onTap: _scanSubsonic)
                  : null,
            ),
            // WebDAV：同上，已配置时行尾提供重新扫描按钮
            _SourceRow(
              icon: LucideIcons.cloud,
              label: l10n.sourceWebdav,
              subtitle: WebdavService.isConfigured
                  ? l10n.sourceWebdavConnected
                  : l10n.sourceWebdavHint,
              connected: WebdavService.isConfigured,
              loading: _webdavScanning,
              result: _webdavResult,
              onTap: _handleWebdav,
              trailing: WebdavService.isConfigured
                  ? _ScanButton(onTap: _scanWebdav)
                  : null,
            ),
            const Spacer(),
            // 底部版本号
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Text(
                'v1.0.0-rc.1',
                style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 抽屉音源行：左侧连接状态点（绿=已连接 / 红=未连接）+ 图标 + 名称 + 副标题，
/// 右侧在扫描时显示进度、扫描后显示结果。点击整行 = 添加/扫描/管理该音源。
class _SourceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool connected;
  final VoidCallback onTap;
  final bool loading;
  final String? result;
  final Widget? trailing;

  const _SourceRow({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.connected,
    required this.onTap,
    this.loading = false,
    this.result,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = connected
        ? const Color(0xFF34C759)
        : const Color(0xFFFF3B30);
    return GestureDetector(
      onTap: loading ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: [
            // 左侧连接状态点
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: dotColor.withValues(alpha: 0.45),
                    blurRadius: 4,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(icon, size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 右侧状态：扫描中 / 扫描结果 / trailing（同步按钮等）
            // result 优先于 trailing：扫描完成显示"发现歌曲/失败"文案，
            // 下次重扫前清空 result 后恢复同步按钮
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.textSecondary,
                ),
              )
            else if (result != null)
              Text(
                result!,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textTertiary,
                ),
              )
            else
              ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 行尾"重新扫描"按钮（Subsonic/WebDAV 已配置时显示，与 NAS 同步按钮
/// 同款视觉）：扫描中由 _SourceRow 的 loading 分支接管转圈，此处只渲
/// 染可点击图标。
class _ScanButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ScanButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 热区 36×36（含空隙），图标视觉 16×16 不变
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const Padding(
        padding: EdgeInsets.all(10),
        child: Icon(
          LucideIcons.refreshCw,
          size: 16,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}

/// NAS 行右侧同步按钮：点击重新扫描 NAS 并合并曲库（同步新增/删除）；
/// 同步中显示转圈，点击行仍可进设置页。
class _NasSyncButton extends ConsumerWidget {
  final bool syncing;

  const _NasSyncButton({required this.syncing});

  void _sync(WidgetRef ref) {
    final share = PreferencesService.instance.nasShare;
    if (share == null || share.isEmpty) return;
    ref.read(libraryProvider.notifier).startNasImport(share);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (syncing) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      // 热区 36×36（含空隙），图标视觉 16×16 不变
      behavior: HitTestBehavior.opaque,
      onTap: () => _sync(ref),
      child: const Padding(
        padding: EdgeInsets.all(10),
        child: Icon(
          LucideIcons.refreshCw,
          size: 16,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: active
              ? AppTheme.textTertiary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 20,
          color: active ? AppTheme.textPrimary : AppTheme.textSecondary,
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.brand.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: isSelected ? AppTheme.brand : AppTheme.textTertiary,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppTheme.brand : AppTheme.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
