import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/rust_service.dart';
import 'providers/playback_provider.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尝试加载 Rust native 库（设备/模拟器上有效，纯 Dart 环境忽略）
  await initRust();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(
    ChangeNotifierProvider(
      create: (_) => PlaybackProvider(),
      child: const WaveLinkApp(),
    ),
  );
}
