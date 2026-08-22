import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/theme.dart';
import 'l10n/app_localizations.dart';
import 'screens/home.dart';
import 'services/locale_provider.dart';
import 'services/network_source_config.dart';
import 'services/player_providers.dart';
import 'services/tray_service.dart';
import 'widgets/brand_splash.dart';

/// Intercept the window close button so the app minimizes to the tray instead
/// of quitting (the tray menu "退出" triggers a real destroy).
class _AppWindowListener with WindowListener {
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 封面内存缓存调大：曲库动辄上千首，Flutter 默认 ImageCache（1000 张/100MB）
  // 在快速滚动时频繁 LRU 逐出，导致封面反复重新解码、滚动时闪现占位色块。
  // 桌面端列表窗口更大，一次可见封面更多，给足内存。
  PaintingBinding.instance.imageCache
    ..maximumSize = 3000
    ..maximumSizeBytes = 384 << 20;

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(920, 660),
    center: true,
    title: 'WaveLink',
    minimumSize: Size(720, 520),
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  // 保存引用以便退出时移除（匿名实例 addListener 后无法 remove）。
  final windowListener = _AppWindowListener();
  windowManager.addListener(windowListener);
  await windowManager.setPreventClose(true);

  // 单一 ProviderContainer：main 与 UI 共享同一个播放器 provider，
  // 避免 Riverpod Provider 再创建实例导致双实例。
  final container = ProviderContainer();
  final player = container.read(playerProvider.notifier);

  // 先渲染 UI，再异步初始化（引擎加载 + 持久化文件夹重扫可能耗时数秒，
  // 阻塞 runApp 会导致大曲库白屏启动；曲库就绪后经 PlayerState 下发通知 UI）。
  // 网络音源配置（WebDAV/NAS/Subsonic 凭据、展示开关）必须先初始化：
  // 侧栏在 runApp 后即构建并读取凭据，PlayerNotifier.init 也会用到。
  await NetworkSourceConfig.init();

  // _MacAppMenu：macOS 原生菜单栏（⌘Q/关于），其余平台为空壳直通
  runApp(UncontrolledProviderScope(
    container: container,
    child: const _MacAppMenu(child: MyApp()),
  ));

  // 初始化失败不崩溃：记录日志，曲库/引擎就绪通知靠 player 内部错误流兜底。
  try {
    await player.init();
  } catch (e) {
    debugPrint('player.init failed: $e');
  }

  final tray = TrayService(container);
  await tray.init();

  // macOS Dock 菜单（右键图标：播放/暂停 + 下一首）：
  // 推送播放态给原生刷新标题；接收原生控制动作回传。
  if (Platform.isMacOS) {
    const dock = MethodChannel('wavelink/dock');
    void pushPlaying(bool playing) {
      dock.invokeMethod('setPlaying', playing).catchError((_) {});
    }

    container.listen(
      playerProvider.select((s) => s.playing),
      (_, playing) => pushPlaying(playing),
    );
    // 初始态同步（启动即播放的恢复场景）
    pushPlaying(container.read(playerProvider).playing);
    dock.setMethodCallHandler((call) async {
      final player = container.read(playerProvider.notifier);
      switch (call.method) {
        case 'togglePlay':
          await player.togglePlay();
        case 'next':
          await player.next();
      }
      return null;
    });
  }
}

/// 去掉桌面端滚动到边界时的发光/拉伸回弹（Material 默认在移动端有蓝色 overscroll
/// glow，桌面端若出现会显得很「移动 Flutter」）。统一以无指示器的原生滚动表现。
class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(localeProvider);
    final deviceLocale = PlatformDispatcher.instance.locale;
    final locale = LocaleNotifier.resolve(mode, deviceLocale);
    return MaterialApp(
      navigatorKey: _MacAppMenu.navKey,
      title: 'WaveLink',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      scrollBehavior: _NoGlowScrollBehavior(),
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleNotifier.supported,
      home: const SplashGate(child: HomeScreen()),
    );
  }
}

/// macOS 原生应用菜单（App Menu）：补齐 ⌘Q 退出、关于面板。
/// （文本编辑组快捷键 ⌘C/⌘V/⌘A 由 Flutter 文本框默认处理，无需菜单项。）
/// Windows/Linux 不构建（PlatformMenuBar 在非 Apple 平台为空实现）。
class _MacAppMenu extends StatelessWidget {
  final Widget child;
  const _MacAppMenu({required this.child});

  /// 关于面板需 context 弹窗，MaterialApp 挂此 key 供回调取 Navigator。
  static final GlobalKey<NavigatorState> navKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    // PlatformMenuBar 在 MaterialApp 之外，拿不到 l10n delegate；
    // 按系统语言手动解析（仅菜单几个词，不值得引入完整方案）
    final zh = PlatformDispatcher.instance.locale.languageCode == 'zh';
    final ja = PlatformDispatcher.instance.locale.languageCode == 'ja';
    final de = PlatformDispatcher.instance.locale.languageCode == 'de';
    final about = de
        ? 'Über WaveLink'
        : ja
            ? 'WaveLink について'
            : zh
                ? '关于 WaveLink'
                : 'About WaveLink';
    final quit = de
        ? 'Beenden'
        : ja
            ? '終了'
            : zh
                ? '退出 WaveLink'
                : 'Quit WaveLink';
    return PlatformMenuBar(
      menus: [
        PlatformMenuItemGroup(members: [
          PlatformMenuItem(label: about, onSelected: _showAbout),
        ]),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: quit,
              shortcut:
                  const SingleActivator(LogicalKeyboardKey.keyQ, meta: true),
              // 托盘 preventClose 只拦窗口 X，⌘Q 必须真销毁
              onSelected: () => windowManager.destroy(),
            ),
          ],
        ),
      ],
      child: child,
    );
  }

  static void _showAbout() {
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    showAboutDialog(
      context: ctx,
      applicationName: 'WaveLink',
      applicationVersion: '1.0.0',
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset('assets/splash/logo.png', width: 48, height: 48),
      ),
      children: const [Text('本地 / 网络音乐播放器 · hi-res 音频引擎')],
    );
  }
}
