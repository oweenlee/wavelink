import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'data/services/library_cache_service.dart';
import 'data/services/log.dart';
import 'data/services/rust_service.dart';
import 'data/services/smb_service.dart';
import 'data/services/preferences_service.dart';
import 'data/services/subsonic_service.dart';
import 'ui/features/library/view_models/library_provider.dart';
import 'ui/features/playback/view_models/playback_controller.dart';
import 'ui/core/app.dart';
import 'ui/core/widgets/brand_splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 封面内存缓存调大：曲库动辄上千首，Flutter 默认 ImageCache（1000 张/100MB）
  // 在快速滚动时频繁 LRU 逐出，导致封面反复重新解码、滚动时闪现占位色块。
  PaintingBinding.instance.imageCache
    ..maximumSize = 2000
    ..maximumSizeBytes = 256 << 20;

  // 分级日志落盘（ring buffer，诊断页可查看/清空）。
  // 尽早初始化，把启动阶段的日志也捕获下来。
  await Log.init();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final container = ProviderContainer();

  // 第一步：立即渲染纯黑首帧，与原生启动屏（#0A0A0A）无缝衔接。
  // 异步初始化不再阻塞首帧，杜绝原生启动屏消失后到 Flutter 首帧
  // 之间出现灰色空窗（iOS Main.storyboard / Android NormalTheme 背景）。
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ColoredBox(
        color: Color(0xFF0A0A0A),
        child: SizedBox.expand(),
      ),
    ),
  );

  // 偏好持久化
  await PreferencesService.init();
  // Subsonic 服务器配置恢复（不发起网络请求，无权限弹窗）
  SubsonicService.loadFromPrefs();

  // 尝试加载 Rust native 库（设备/模拟器上有效，纯 Dart 环境忽略）
  await initRust();

  // 恢复上次持久化的曲库（不自动扫描系统媒体库：权限弹窗
  // 只在用户主动 Discover/添加音源时触发，避免启动即弹窗）
  container.read(libraryProvider.notifier).restoreCachedSongs(
        await LibraryCacheService.loadSongs(),
      );
  // 触发编排层接线，随后启动副作用（偏好加载、播放器 init、曲库扫描）
  container.read(playbackControllerProvider).bootstrap();

  // NAS/SMB 会话自愈：后台挂起会掐掉 SMB socket 但 Rust 侧无感知，
  // 恢复前台时主动重建会话，避免下次 IO 在假活连接上白等 30s 超时。
  if (kIsWeb) return;
  WidgetsBinding.instance.addObserver(_SmbLifecycleObserver());

  // 第二步：初始化完成，挂载品牌动效 + 主应用。
  // 两段均为黑底，视觉上无缝（黑 → BrandSplash 脉冲 → 淡出主界面）。
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: SplashGate(child: const WaveLinkApp()),
    ),
  );
}

/// 监听 app 前后台切换，后台停留超过阈值后恢复时重建 SMB 会话。
/// 需要而无需手动挂载生命周期：
/// - 后台挂起期间 iOS 会回收网络 socket，Rust SMB 会话无感知变成「假活」；
/// - 恢复时主动 force 重建，避免首 IO 白等 smb2 的 30s 超时。
class _SmbLifecycleObserver with WidgetsBindingObserver {
  DateTime? _backgroundedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // iOS 进入后台通常先 inactive→paused；只记第一次的时间
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _backgroundedAt ??= DateTime.now();
      final gap = DateTime.now().difference(_backgroundedAt!);
      _backgroundedAt = null;
      if (gap.inSeconds >= 30) {
        unawaited(SmbService.recoverAfterBackground(gap));
      }
      return;
    }
    _backgroundedAt = null;
  }
}
