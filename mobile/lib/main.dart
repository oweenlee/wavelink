import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'data/services/library_cache_service.dart';
import 'data/services/rust_service.dart';
import 'data/services/preferences_service.dart';
import 'ui/features/library/view_models/library_provider.dart';
import 'ui/features/playback/view_models/playback_controller.dart';
import 'ui/core/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 偏好持久化
  await PreferencesService.init();

  // 尝试加载 Rust native 库（设备/模拟器上有效，纯 Dart 环境忽略）
  await initRust();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final container = ProviderContainer();
  // 恢复上次持久化的曲库，随后系统扫描增量合并
  container.read(libraryProvider.notifier).restoreCachedSongs(
        await LibraryCacheService.loadSongs(),
      );
  // 触发编排层接线，随后启动副作用（偏好加载、播放器 init、曲库扫描）
  container.read(playbackControllerProvider).bootstrap();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const WaveLinkApp(),
    ),
  );
}
