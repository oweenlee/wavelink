import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/rust_service.dart';
import 'services/preferences_service.dart';
import 'providers/playback_provider.dart';
import 'providers/locale_provider.dart';
import 'app.dart';

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

  final playback = PlaybackProvider();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: playback.queueProvider),
        ChangeNotifierProvider.value(value: playback.audioPlayer),
        ChangeNotifierProvider.value(value: playback.library),
        ChangeNotifierProvider.value(value: playback.dsp),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
      ],
      child: const WaveLinkApp(),
    ),
  );
}
