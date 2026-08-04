import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/repositories/audio_engine_repository.dart';
import '../../../data/repositories/song_repository.dart';
import '../../../data/repositories/preferences_repository.dart';

/// Repository 层统一由 Riverpod 注入，测试用 overrideWith 替换为 mock。
final audioEngineRepositoryProvider = Provider<AudioEngineRepository>((ref) {
  return AudioEngineRepository();
});

final songRepositoryProvider = Provider<SongRepository>((ref) {
  return SongRepository();
});

final preferencesRepositoryProvider = Provider<PreferencesRepository>((ref) {
  return PreferencesRepository();
});
