import '../../../../data/repositories/audio_engine_repository.dart';
import 'playback_backend.dart';

/// Rust 音频引擎后端：当前唯一实现，委托给 AudioEngineRepository。
///
/// 引擎专属能力（DSP/probe/遥测/ReplayGain/分析）不在此接口内，
/// 由播放器继续经 audioEngineRepositoryProvider 按能力守卫调用。
class RustEngineBackend implements PlaybackBackend {
  RustEngineBackend(this._repo);

  final AudioEngineRepository _repo;

  @override
  bool get available => _repo.rustAvailable;

  @override
  Future<void> play(String path) => _repo.play(path);

  @override
  Future<void> pause() => _repo.pause();

  @override
  Future<void> resume() => _repo.resume();

  @override
  Future<void> seek(double posSecs) => _repo.seek(posSecs);

  @override
  Future<double> positionSecs() => _repo.positionSecs();

  @override
  Future<String?> pollEvents() => _repo.pollEvents();

  @override
  Future<String> lastError() => _repo.lastError();

  @override
  Future<bool> isPlaying() => _repo.isPlaying();

  @override
  Future<void> dispose() => _repo.deinitEngine();
}
