import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/repositories/audio_engine_repository.dart';
import '../../../data/repositories/song_repository.dart';
import '../../../data/repositories/preferences_repository.dart';
import '../../features/playback/backends/playback_backend.dart';
import '../../features/playback/backends/rust_engine_backend.dart';

/// Repository 层统一由 Riverpod 注入，测试用 overrideWith 替换为 mock。
final audioEngineRepositoryProvider = Provider<AudioEngineRepository>((ref) {
  return AudioEngineRepository();
});

/// 播放传输层后端：当前唯一实现为 Rust 引擎。
/// 内部 watch 引擎仓库，测试 override 仓库后此处自动拿到 mock 后端。
final playbackBackendProvider = Provider<PlaybackBackend>((ref) {
  return RustEngineBackend(ref.watch(audioEngineRepositoryProvider));
});

final songRepositoryProvider = Provider<SongRepository>((ref) {
  return SongRepository();
});

final preferencesRepositoryProvider = Provider<PreferencesRepository>((ref) {
  return PreferencesRepository();
});
