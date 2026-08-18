import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/theme.dart';
import 'screens/home.dart';
import 'services/network_source_config.dart';
import 'services/player_providers.dart';
import 'services/tray_service.dart';

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

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(920, 660),
    center: true,
    title: '本地音乐播放器',
    minimumSize: Size(720, 520),
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  windowManager.addListener(_AppWindowListener());
  await windowManager.setPreventClose(true);

  // 单一 ProviderContainer：main 与 UI 共享同一个播放控制器实例，
  // 避免 Riverpod Provider 再创建实例导致双实例。
  final container = ProviderContainer();
  final player = container.read(playerControllerProvider);

  // 先渲染 UI，再异步初始化（引擎加载 + 持久化文件夹重扫可能耗时数秒，
  // 阻塞 runApp 会导致大曲库白屏启动；曲库就绪后经 libraryStream 通知 UI）。
  // 网络音源配置（WebDAV/NAS/Subsonic 凭据、展示开关）必须先初始化：
  // 侧栏在 runApp 后即构建并读取凭据，PlayerController.init 也会用到。
  await NetworkSourceConfig.init();

  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));

  await player.init();

  final tray = TrayService(player);
  await tray.init();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaveLink',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
