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
import '../../src/rust/api/smb.dart' as smb;
import '../../src/rust/api/webdav.dart' as webdav;
import '../../src/rust/api/room.dart' as room;
import 'log.dart';

export '../../src/rust/api/decode.dart'
    show DecodeResult, DecodeChunk, StreamDecoder;
export '../../src/rust/api/analyze.dart' show AnalyzeResult;
export '../../src/rust/api/metadata.dart' show MetadataResult, ReplayGainResult;
export '../../src/rust/api/cue.dart'
    show CueSheetResult, CueFileResult, CueTrackResult;
export '../../src/rust/api/playlist.dart' show PlaylistEntryResult;
export '../../src/rust/api/engine.dart' show LevelsDto;
export '../../src/rust/api/room.dart'
    show CorrectionConfig, FreqPoint, RoomCorrectionResult;

/// Rust 后端是否已加载
bool rustAvailable = false;

/// 初始化 Rust native 库
Future<void> initRust() async {
  try {
    await RustLib.init();
    rustAvailable = true;
  } catch (e) {
    Log.e('Rust', '初始化失败: $e');
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

/// SMB 边下边播：Rust 侧启动 core 流式播放（首帧即出声）并后台喂流，
/// 并行把内容写入 [cacheFinalPath]（完成后 rename 成正式缓存）。
Future<void> enginePlaySmbStream({
  required String smbPath,
  String? formatHint,
  String? cacheFinalPath,
}) => smb.enginePlaySmbStream(
  smbPath: smbPath,
  formatHint: formatHint,
  cacheFinalPath: cacheFinalPath,
);

/// WebDAV 边下边播：Rust 侧用 reqwest 流式 GET 拉远端字节喂入 core
/// （首帧即出声），并行把内容写入 [cacheFinalPath]（完成后 rename 成
/// 正式缓存）。认证支持 Basic/Digest。
Future<void> enginePlayWebdavStream({
  required String url,
  required String username,
  required String password,
  String? formatHint,
  String? cacheFinalPath,
}) => webdav.enginePlayWebdavStream(
  url: url,
  username: username,
  password: password,
  formatHint: formatHint,
  cacheFinalPath: cacheFinalPath,
);

/// 读取 WebDAV 远端文件前缀字节（封面/歌词提取用），Range 请求，
/// 只拉取前 [maxLen] 字节（服务器忽略 Range 时也主动截断）。
/// 读取 WebDAV 远端文件头/尾字节（封面/歌词提取用）。[suffix] 为 true 时
/// 读文件尾（Range: bytes=-N），否则读文件头（Range: bytes=0-(N-1)）。
Future<Uint8List> readWebdavRange({
  required String url,
  required String username,
  required String password,
  required int maxLen,
  required bool suffix,
}) => webdav.engineReadWebdavRange(
  url: url,
  username: username,
  password: password,
  maxLen: BigInt.from(maxLen),
  suffix: suffix,
);

/// 获取 WebDAV 远端文件大小（并发分片下载前置探大小）。
Future<int> webdavFileSize({
  required String url,
  required String username,
  required String password,
}) async =>
    (await webdav.engineWebdavFileSize(
      url: url,
      username: username,
      password: password,
    ))
        .toInt();

/// 读取 WebDAV 远端文件指定区间 `[offset, offset+maxLen)`（并发分片下载原语）。
Future<Uint8List> webdavDownloadRange({
  required String url,
  required String username,
  required String password,
  required int offset,
  required int maxLen,
}) => webdav.engineWebdavDownloadRange(
  url: url,
  username: username,
  password: password,
  offset: BigInt.from(offset),
  maxLen: BigInt.from(maxLen),
);

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
    Log.e('Rust', '获取频谱失败: $e');
    return List.filled(16, 0.0);
  }
}

Future<int> getUnderrunCount() async {
  if (!rustAvailable) return 0;
  try {
    return (await audio_out.getUnderrunCount()).toInt();
  } catch (e) {
    Log.e('Rust', '获取 underrun 失败: $e');
    return 0;
  }
}

/// 当前硬件/输出采样率（Hz）。iOS 由 Swift 经 set_hw_sample_rate 写入。
Future<int> getHwSampleRate() async {
  if (!rustAvailable) return 0;
  try {
    return await audio_out.getHwSampleRate();
  } catch (e) {
    Log.e('Rust', '获取硬件采样率失败: $e');
    return 0;
  }
}

// ── 房间校正（REW → 校正 FIR → IR WAV）──

/// 默认校正配置（与 core 对齐）
Future<room.CorrectionConfig> defaultCorrectionConfig() =>
    room.defaultCorrectionConfig();

/// 解析 REW 频响导出文本（不生成 IR，预览/校验用）
Future<List<room.FreqPoint>> parseRewText(String text) =>
    room.parseRewText(text: text);

/// 生成房间校正 IR：REW 测量文本 → 校正 FIR 系数 + 测量曲线预览
Future<room.RoomCorrectionResult> generateRoomCorrection({
  required String rewTxt,
  required room.CorrectionConfig config,
  required int sampleRate,
}) => room.generateRoomCorrection(
  rewTxt: rewTxt,
  config: config,
  sampleRate: sampleRate,
);

/// 保存 IR 为 32-bit float WAV（供 engineLoadIr 加载）
Future<void> saveRoomIrWav(List<double> ir, int sampleRate, String path) =>
    room.saveIrWav(ir: ir, sampleRate: sampleRate, path: path);

/// 加载房间校正 IR（WAV 路径）到 DSP 卷积级；重复加载会替换旧 IR
Future<void> engineLoadIr({required String path}) =>
    engine.engineLoadIr(path: path);

/// 清除卷积 IR（恢复直通）
Future<void> engineClearIr() => engine.engineClearIr();
