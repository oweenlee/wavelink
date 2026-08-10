import 'dart:typed_data';
import '../services/rust_service.dart' as rs;

/// Rust 音频引擎的数据访问封装
///
/// 职责：
/// - 引擎生命周期管理（init/deinit）
/// - 播放控制（play/pause/resume/stop/seek）
/// - 音量控制
/// - DSP 设置（preset/crossfeed/widener）
/// - 状态查询（position/duration/events）
/// - 音频分析结果缓存
/// - 频谱 & underrun 查询
class AudioEngineRepository {
  final Map<String, rs.AnalyzeResult> _analysisCache = {};

  // ── 生命周期 ──

  Future<void> initEngine() => rs.initEngine();
  Future<void> initEngineAt(int sampleRate) => rs.initEngineAt(sampleRate);
  Future<void> deinitEngine() => rs.deinitEngine();

  // ── 播放控制 ──

  Future<void> play(String path) => rs.enginePlay(path);
  Future<void> pause() => rs.enginePause();
  Future<void> resume() => rs.engineResume();
  Future<void> stop() => rs.engineStop();
  Future<void> seek(double posSecs) => rs.engineSeek(posSecs);

  /// 从引擎 ringbuf 读取交错立体声 PCM（Android 流式播放拉取用）
  Future<Float32List> readPcm(int frames) => rs.engineReadSamplesFrames(frames);

  /// 设置引擎输出采样率（下次播放生效，iOS bit-perfect 协调用）
  Future<void> setOutputSampleRate(int rate) =>
      rs.engineSetOutputSampleRate(rate: rate);

  /// 探测音频文件采样率（失败返回 0）
  Future<int> probeSampleRate(String path) => rs.probeSampleRate(path);

  /// 探测音频文件时长秒数（失败返回 0；仅头部读取，不完整解码）
  Future<double> probeDurationSecs(String path) => rs.probeDurationSecs(path);

  // ── 音量 ──

  Future<void> setVolume(double vol) => rs.engineSetVolume(vol: vol);

  // ── DSP ──

  Future<void> applyPreset(String name) =>
      rs.engineApplyPreset(presetName: name);
  Future<void> setPeqBand(int index, double freq, double gainDb, double q) =>
      rs.engineSetPeqBand(index: index, freq: freq, gainDb: gainDb, q: q);
  Future<void> setCrossfeed(bool enabled) =>
      rs.engineSetCrossfeed(enabled: enabled);
  Future<void> setStereoWidener(bool enabled, double width) =>
      rs.engineSetStereoWidener(enabled: enabled, width: width);
  Future<void> setLimiter(bool enabled) =>
      rs.engineSetLimiter(enabled: enabled);
  Future<void> setDither(bool enabled) =>
      rs.engineSetDither(enabled: enabled);
  Future<void> setNoiseShaping(bool enabled) =>
      rs.engineSetNoiseShaping(enabled: enabled);

  /// AutoEQ 耳机校正：应用型号档案（null 清除）
  Future<void> setAutoEq(String? model) => rs.engineSetAutoEq(model: model);

  /// AutoEQ 档案目录（型号名列表，设置页选择用）
  Future<List<String>> autoEqCatalog() => rs.autoEqCatalog();

  // ── ReplayGain（切歌时按曲目标签逐首下发）──

  Future<void> setReplaygainGain(double gainDb) =>
      rs.engineSetReplaygainGain(gainDb: gainDb);
  Future<void> setReplaygainPeak(double? peak) =>
      rs.engineSetReplaygainPeak(peak: peak);
  Future<rs.ReplayGainResult> readReplaygain(String path) =>
      rs.readReplaygain(path);

  // ── 会话中断（引擎级暂停/恢复）──

  Future<void> sessionInterruptionBegan() => rs.engineSessionInterruptionBegan();
  Future<void> sessionInterruptionEnded() => rs.engineSessionInterruptionEnded();

  // ── 状态 ──

  Future<String?> pollEvents() => rs.enginePollEvents();
  Future<double> positionSecs() => rs.enginePositionSecs();
  Future<String> lastError() => rs.engineLastError();

  // ── 分析缓存 ──

  Future<rs.AnalyzeResult> analyzeFile(String songId, String path) async {
    final cached = _analysisCache[songId];
    if (cached != null) return cached;
    final result = await rs.analyzeAudioFile(path);
    _analysisCache[songId] = result;
    return result;
  }

  bool hasAnalysis(String songId) => _analysisCache.containsKey(songId);

  rs.AnalyzeResult? getAnalysis(String songId) => _analysisCache[songId];

  void clearAnalysisCache() => _analysisCache.clear();

  // ── Rust 可用性 ──

  bool get rustAvailable => rs.rustAvailable;

  /// 提取音频文件封面字节（非引擎调用，但同属 Rust FFI 范畴）
  Future<Uint8List> getCoverBytes(String path) => rs.getCoverBytes(path);

  // ── 频谱 ──

  Future<List<double>> getSpectrum() => rs.getSpectrum();
  Future<int> getUnderrunCount() => rs.getUnderrunCount();
  Future<int> getHwSampleRate() => rs.getHwSampleRate();
  Future<bool> isPlaying() => rs.engineIsPlaying();

  /// 实际输出共享模式：0=未知/不适用，1=Exclusive，2=Shared（Android Oboe）
  Future<int> getOutputMode() => rs.engineOutputMode();
}
