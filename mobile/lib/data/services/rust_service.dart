import 'package:flutter/foundation.dart';
import '../../src/rust/frb_generated.dart';
import '../../src/rust/api/decode.dart' as decode;
import '../../src/rust/api/analyze.dart' as analyze;
import '../../src/rust/api/metadata.dart' as meta;
import '../../src/rust/api/audio_output.dart' as audio_out;
import '../../src/rust/api/cue.dart' as cue;
import '../../src/rust/api/playlist.dart' as playlist;
import '../../src/rust/api/engine.dart' as engine;
import '../../src/rust/api/dsp.dart' as dsp;

export '../../src/rust/api/decode.dart'
    show DecodeResult, DecodeChunk, StreamDecoder;
export '../../src/rust/api/analyze.dart' show AnalyzeResult;
export '../../src/rust/api/metadata.dart' show MetadataResult, ReplayGainResult;
export '../../src/rust/api/cue.dart'
    show CueSheetResult, CueFileResult, CueTrackResult;
export '../../src/rust/api/playlist.dart' show PlaylistEntryResult;
export '../../src/rust/api/engine.dart' show LevelsDto;

/// Rust 后端是否已加载
bool rustAvailable = false;

/// 初始化 Rust native 库
Future<void> initRust() async {
  try {
    await RustLib.init();
    rustAvailable = true;
  } catch (e) {
    debugPrint('[Rust] 初始化失败: $e');
    rustAvailable = false;
  }
}

// ── 解码 ──

Future<decode.DecodeResult> decodeFile(String path) {
  return decode.decodeFile(path: path);
}

Future<decode.DecodeResult> decodeDsdFile(String path) {
  return decode.decodeDsdFile(path: path);
}

Future<bool> isDsdFile(String path) {
  return decode.isDsdFile(path: path);
}

/// 快速探测音频文件采样率，失败返回 0
Future<int> probeSampleRate(String path) {
  return decode.probeSampleRate(path: path);
}

/// 快速探测音频文件时长秒数，失败返回 0（仅头部读取，不完整解码）
Future<double> probeDurationSecs(String path) {
  return decode.probeDurationSecs(path: path);
}

// ── 分析 ──

Future<analyze.AnalyzeResult> analyzeAudioFile(String path) {
  return analyze.analyzeFile(path: path);
}

Future<analyze.AnalyzeResult> analyzePcmSamples(
  List<double> samples,
  int sampleRate,
  int channels,
) {
  return analyze.analyzePcmSamples(
    samples: samples,
    sampleRate: sampleRate,
    channels: channels,
  );
}

// ── 元数据 ──

Future<meta.MetadataResult> readMetadata(String path) {
  return meta.readMetadata(path: path);
}

Future<Uint8List> getCoverBytes(String path) {
  return meta.getCoverBytes(path: path);
}

/// 读取 ReplayGain 响度归一化增益值
Future<meta.ReplayGainResult> readReplaygain(String path) {
  return meta.readReplaygain(path: path);
}

// ── 流式解码 ──

/// 创建流式解码器（可选 seek_secs：从指定秒数开始解码）
Future<decode.StreamDecoder> streamDecoderCreate(
  String path, {
  double? seekSecs,
}) {
  return decode.streamDecoderCreate(path: path, seekSecs: seekSecs);
}

/// 获取下一块解码数据
Future<decode.DecodeChunk?> streamDecoderNextChunk(
  decode.StreamDecoder decoder,
) {
  return decode.streamDecoderNextChunk(decoder: decoder);
}

/// 停止流式解码
Future<void> streamDecoderStop(decode.StreamDecoder decoder) {
  return decode.streamDecoderStop(decoder: decoder);
}

// ── CUE 分轨 ──

/// 解析 .cue 文件，返回分轨表
Future<cue.CueSheetResult> parseCueFile(String path) {
  return cue.parseCueFile(path: path);
}

// ── 播放列表 ──

/// 解析播放列表文件（自动识别 M3U/M3U8/PLS），返回条目列表
Future<List<playlist.PlaylistEntryResult>> parsePlaylistFile(String path) {
  return playlist.parsePlaylistFile(path: path);
}

// ── 引擎控制 ──

Future<void> initEngine() => engine.engineInit();

/// 以指定输出采样率初始化引擎（Android 对齐设备原生速率用，
/// 其余参数与 engine_init 默认值一致：2ch/280ms 缓冲）
Future<void> initEngineAt(int sampleRate) => engine.engineInitEx(
      sr: sampleRate,
      channels: 2,
      bufferMs: 280,
      crossfadeMs: 0,
      bitPerfect: false,
      autoSampleRate: false,
      exclusiveMode: false,
    );
Future<void> deinitEngine() => engine.engineDeinit();

Future<void> enginePlay(String path) => engine.enginePlay(path: path);
Future<void> enginePlayQueue(List<String> paths) =>
    engine.enginePlayQueue(paths: paths);
Future<void> engineSetPeqBand({
  required int index,
  required double freq,
  required double gainDb,
  required double q,
}) => engine.engineSetPeqBand(index: index, freq: freq, gainDb: gainDb, q: q);
Future<void> engineApplyPreset({required String presetName}) =>
    engine.engineApplyPreset(presetName: presetName);
Future<void> engineSetVolume({required double vol}) =>
    engine.engineSetVolume(vol: vol);
Future<void> engineSetSpeed({required double speed}) =>
    engine.engineSetSpeed(speed: speed);
Future<void> engineSetOutputSampleRate({required int rate}) =>
    engine.engineSetOutputSampleRate(rate: rate);
Future<void> engineSetCrossfeed({required bool enabled}) =>
    engine.engineSetCrossfeed(enabled: enabled);
Future<void> engineSetLimiter({required bool enabled}) =>
    engine.engineSetLimiter(enabled: enabled);
Future<void> engineSetDither({required bool enabled}) =>
    engine.engineSetDither(enabled: enabled);
Future<void> engineSetStereoWidener({
  required bool enabled,
  required double width,
}) => engine.engineSetStereoWidener(enabled: enabled, width: width);
Future<void> engineSetPlayMode({required int mode}) =>
    engine.engineSetPlayMode(mode: mode);
Future<void> engineSetReplaygainGain({required double gainDb}) =>
    engine.engineSetReplaygainGain(gainDb: gainDb);
Future<void> engineSetReplaygainPeak({double? peak}) =>
    engine.engineSetReplaygainPeak(peak: peak);
Future<void> engineSetNoiseShaping({required bool enabled}) =>
    engine.engineSetNoiseShaping(enabled: enabled);
Future<void> engineSetAutoEq({String? model}) =>
    engine.engineSetAutoEq(model: model);
Future<List<String>> autoEqCatalog() => dsp.autoEqCatalog();
Future<void> engineSessionInterruptionBegan() =>
    engine.engineSessionInterruptionBegan();
Future<void> engineSessionInterruptionEnded() =>
    engine.engineSessionInterruptionEnded();

Future<void> enginePause() => engine.enginePause();
Future<void> engineResume() => engine.engineResume();
Future<void> engineStop() => engine.engineStop();
Future<void> engineSeek(double posSecs) => engine.engineSeek(posSecs: posSecs);
Future<void> engineNext() => engine.engineNext();
Future<void> enginePrev() => engine.enginePrev();

/// 从引擎 ringbuf 读取最多 [frames] 帧的交错立体声 PCM（Android 流式播放用）。
/// 返回长度可能小于 frames*2（数据不足），调用方自行处理欠载。
Future<Float32List> engineReadSamplesFrames(int frames) =>
    engine.engineReadSamplesFrames(frames: frames);

Future<String?> enginePollEvents() => engine.enginePollEvents();

Future<double> enginePositionSecs() => engine.enginePositionSecs();
Future<double> engineDurationSecs() => engine.engineDurationSecs();
Future<bool> engineIsPlaying() => engine.engineIsPlaying();
Future<int> engineOutputMode() => engine.engineOutputMode();
Future<String> engineCurrentPath() => engine.engineCurrentPath();
Future<String> engineLastError() => engine.engineLastError();

// ── 频谱 / underrun ──

Future<List<double>> getSpectrum() async {
  if (!rustAvailable) return List.filled(16, 0.0);
  try {
    final raw = await audio_out.getSpectrum();
    return raw.map((e) => e.toDouble()).toList();
  } catch (e) {
    debugPrint('[Rust] 获取频谱失败: $e');
    return List.filled(16, 0.0);
  }
}

Future<int> getUnderrunCount() async {
  if (!rustAvailable) return 0;
  try {
    return (await audio_out.getUnderrunCount()).toInt();
  } catch (e) {
    debugPrint('[Rust] 获取 underrun 失败: $e');
    return 0;
  }
}

/// 当前硬件/输出采样率（Hz）。iOS 由 Swift 经 set_hw_sample_rate 写入。
Future<int> getHwSampleRate() async {
  if (!rustAvailable) return 0;
  try {
    return await audio_out.getHwSampleRate();
  } catch (e) {
    debugPrint('[Rust] 获取硬件采样率失败: $e');
    return 0;
  }
}
