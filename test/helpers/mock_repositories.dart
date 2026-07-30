import 'dart:typed_data';
import 'package:wavelink_mobile/data/repositories/audio_engine_repository.dart';
import 'package:wavelink_mobile/data/repositories/song_repository.dart';
import 'package:wavelink_mobile/data/services/rust_service.dart' as rs;
import 'package:wavelink_mobile/domain/models/song.dart';

/// 测试用假引擎仓库：覆写所有方法，完全不触碰 Rust / flutter_rust_bridge，
/// 使 PlaybackProvider 等可在纯 Dart 测试环境（无原生库、无 RustLib.init）中构造。
///
/// 同时记录关键调用，便于断言。
class MockAudioEngineRepository extends AudioEngineRepository {
  final List<double> volumeCalls = [];
  final List<String> playCalls = [];
  double position = 0.0;

  /// 下一次 pollEvents 返回的事件（null = 无事件）
  String? nextEvent;

  @override
  Future<void> initEngine() async {}
  @override
  Future<void> deinitEngine() async {}

  @override
  Future<void> play(String path) async {
    playCalls.add(path);
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(double posSecs) async {
    position = posSecs;
  }

  @override
  Future<void> setOutputSampleRate(int rate) async {}

  @override
  Future<int> probeSampleRate(String path) async => 44100;

  @override
  Future<void> setVolume(double vol) async {
    volumeCalls.add(vol);
  }

  @override
  Future<void> applyPreset(String name) async {}
  @override
  Future<void> setCrossfeed(bool enabled) async {}
  @override
  Future<void> setStereoWidener(bool enabled, double width) async {}

  @override
  Future<String?> pollEvents() async => nextEvent;

  @override
  Future<double> positionSecs() async => position;

  @override
  Future<String> lastError() async => '';

  @override
  Future<rs.AnalyzeResult> analyzeFile(String songId, String path) async =>
      const rs.AnalyzeResult();

  @override
  Future<Uint8List> getCoverBytes(String path) async => Uint8List(0);

  @override
  Future<List<double>> getSpectrum() async => List.filled(16, 0.0);

  @override
  Future<int> getUnderrunCount() async => 0;

  @override
  bool get rustAvailable => false;
}

/// 测试用假曲库仓库：扫描方法返回空列表，不触碰 MethodChannel / ImportService。
class MockSongRepository extends SongRepository {
  List<Song> songsToReturn = [];

  @override
  Future<List<Song>> scanMediaStore() async => songsToReturn;
  @override
  Future<List<Song>> scanDocuments() async => [];
  @override
  Future<List<Song>> scanAll() async => songsToReturn;
  @override
  Future<List<Song>> pickAndImport() async => [];
  @override
  Future<List<Song>> scanSubsonic() async => [];
  @override
  Future<List<Song>> scanSmb(String sharePath) async => [];
  @override
  Future<void> cacheCovers(List<Song> songs) async {}
}
