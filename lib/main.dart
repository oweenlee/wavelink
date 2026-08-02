import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'data/services/rust_service.dart';
import 'data/services/preferences_service.dart';
import 'data/repositories/audio_engine_repository.dart';
import 'data/repositories/song_repository.dart';
import 'data/repositories/preferences_repository.dart';
import 'ui/features/playback/view_models/playback_provider.dart';
import 'ui/features/settings/view_models/locale_provider.dart';
import 'ui/features/library/view_models/library_header_notifier.dart';
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

  // 创建 Repository 层
  final engineRepo = AudioEngineRepository();
  final songRepo = SongRepository();
  final prefsRepo = PreferencesRepository();

  final playback = PlaybackProvider(
    engineRepo: engineRepo,
    songRepo: songRepo,
    prefsRepo: prefsRepo,
  );
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: playback.queueProvider),
        ChangeNotifierProvider.value(value: playback.audioPlayer),
        ChangeNotifierProvider.value(value: playback.library),
        ChangeNotifierProvider.value(value: playback.dsp),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => LibraryHeaderNotifier()),
      ],
      child: const WaveLinkApp(),
    ),
  );
}
