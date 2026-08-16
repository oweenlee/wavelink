import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
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

  /// SMB 边下边播：Rust 侧启动 core 流式播放（首帧即出声）并后台喂流，
  /// 并行把内容写入 [cacheFinalPath]（完成后 rename 成正式缓存）。
  /// 返回即代表流已启动（引擎正在解码远端字节流）。
  Future<void> playSmbStream(
    String smbPath,
    String? formatHint,
    String? cacheFinalPath,
  ) => rs.enginePlaySmbStream(
    smbPath: smbPath,
    formatHint: formatHint,
    cacheFinalPath: cacheFinalPath,
  );

  /// WebDAV 边下边播：Rust 侧用 reqwest 流式 GET 拉远端字节喂入 core
  /// （首帧即出声），并行把内容写入 [cacheFinalPath]（完成后 rename 成
  /// 正式缓存）。认证支持 Basic/Digest。返回即代表流已启动。
  Future<void> playWebdavStream(
    String url,
    String username,
    String password,
    String? formatHint,
    String? cacheFinalPath,
  ) => rs.enginePlayWebdavStream(
    url: url,
    username: username,
    password: password,
    formatHint: formatHint,
    cacheFinalPath: cacheFinalPath,
  );

  /// 读取 WebDAV 远端文件头/尾字节（封面/歌词提取用）。[suffix] 为 true 时
  /// 读文件尾（Range: bytes=-N），否则读文件头（Range: bytes=0-(N-1)）。
  Future<Uint8List> readWebdavRange(
    String url,
    String username,
    String password,
    int maxLen,
    bool suffix,
  ) => rs.readWebdavRange(
    url: url,
    username: username,
    password: password,
    maxLen: maxLen,
    suffix: suffix,
  );
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
  Future<void> setDither(bool enabled) => rs.engineSetDither(enabled: enabled);
  Future<void> setNoiseShaping(bool enabled) =>
      rs.engineSetNoiseShaping(enabled: enabled);

  /// AutoEQ 耳机校正：应用型号档案（null 清除）
  Future<void> setAutoEq(String? model) => rs.engineSetAutoEq(model: model);

  /// AutoEQ 档案目录（型号名列表，设置页选择用）
  Future<List<String>> autoEqCatalog() => rs.autoEqCatalog();

  // ── 房间校正（REW → 校正 FIR）──

  Future<rs.CorrectionConfig> defaultCorrectionConfig() =>
      rs.defaultCorrectionConfig();

  Future<List<rs.FreqPoint>> parseRewText(String text) => rs.parseRewText(text);

  Future<rs.RoomCorrectionResult> generateRoomCorrection({
    required String rewTxt,
    required rs.CorrectionConfig config,
    required int sampleRate,
  }) => rs.generateRoomCorrection(
    rewTxt: rewTxt,
    config: config,
    sampleRate: sampleRate,
  );

  Future<void> saveRoomIrWav(List<double> ir, int sampleRate, String path) =>
      rs.saveRoomIrWav(ir, sampleRate, path);

  Future<void> loadRoomIr(String path) => rs.engineLoadIr(path: path);

  /// 清除卷积 IR（恢复直通）
  Future<void> clearRoomIr() => rs.engineClearIr();

  // ── ReplayGain（切歌时按曲目标签逐首下发）──

  Future<void> setReplaygainGain(double gainDb) =>
      rs.engineSetReplaygainGain(gainDb: gainDb);
  Future<void> setReplaygainPeak(double? peak) =>
      rs.engineSetReplaygainPeak(peak: peak);
  Future<rs.ReplayGainResult> readReplaygain(String path) =>
      rs.readReplaygain(path);

  // ── 会话中断（引擎级暂停/恢复）──

  Future<void> sessionInterruptionBegan() =>
      rs.engineSessionInterruptionBegan();
  Future<void> sessionInterruptionEnded() =>
      rs.engineSessionInterruptionEnded();

  // ── 状态 ──

  Future<String?> pollEvents() => rs.enginePollEvents();
  Future<double> positionSecs() => rs.enginePositionSecs();
  Future<String> lastError() => rs.engineLastError();

  // ── 分析缓存 ──

  Future<rs.AnalyzeResult> analyzeFile(String songId, String path) async {
    final cached = _analysisCache[songId];
    if (cached != null) return cached;

    // 磁盘缓存（带 mtime 校验）：二次播放秒出，不重跑全曲分析
    final disk = await _loadDiskAnalysis(path);
    if (disk != null) {
      _analysisCache[songId] = disk;
      return disk;
    }

    final result = await rs.analyzeAudioFile(path);
    _analysisCache[songId] = result;
    unawaited(_saveDiskAnalysis(path, result));
    return result;
  }

  bool hasAnalysis(String songId) => _analysisCache.containsKey(songId);

  rs.AnalyzeResult? getAnalysis(String songId) => _analysisCache[songId];

  void clearAnalysisCache() => _analysisCache.clear();

  /// 稳定字符串 hash（FNV-1a；Dart 的 String.hashCode 跨进程不保证稳定，
  /// 不能用作磁盘缓存文件名）
  static int _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  Future<File?> _analysisCacheFile(String path) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/.analysis_cache');
      if (!await cacheDir.exists()) return null;
      return File('${cacheDir.path}/${_stableHash(path)}.json');
    } catch (_) {
      return null;
    }
  }

  Future<rs.AnalyzeResult?> _loadDiskAnalysis(String path) async {
    try {
      final file = await _analysisCacheFile(path);
      if (file == null || !await file.exists()) return null;
      final mtimeMs = (await File(path).lastModified()).millisecondsSinceEpoch;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // 音频文件内容已变化（路径复用但 mtime 不同）→ 缓存作废重算
      if (data['mtimeMs'] != mtimeMs) return null;
      return rs.AnalyzeResult(
        bpm: (data['bpm'] as num?)?.toDouble(),
        key: data['key'] as String?,
        energy: (data['energy'] as num?)?.toDouble(),
        bpmConfidence: (data['bpmConfidence'] as num?)?.toDouble(),
        keyConfidence: (data['keyConfidence'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDiskAnalysis(String path, rs.AnalyzeResult result) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/.analysis_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final mtimeMs = (await File(path).lastModified()).millisecondsSinceEpoch;
      await File('${cacheDir.path}/${_stableHash(path)}.json').writeAsString(
        jsonEncode({
          'mtimeMs': mtimeMs,
          'bpm': result.bpm,
          'key': result.key,
          'energy': result.energy,
          'bpmConfidence': result.bpmConfidence,
          'keyConfidence': result.keyConfidence,
        }),
      );
    } catch (_) {
      // 缓存写入失败不影响播放
    }
  }

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
