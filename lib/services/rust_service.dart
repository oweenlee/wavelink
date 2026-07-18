import '../src/rust/frb_generated.dart';
import '../src/rust/api/decode.dart' as decode;
import '../src/rust/api/analyze.dart' as analyze;
import '../src/rust/api/dsp.dart' as dsp;
import '../src/rust/api/metadata.dart' as meta;
import '../src/rust/api/audio_output.dart' as audio_out;

export '../src/rust/api/decode.dart' show DecodeResult, DecodeChunk, StreamDecoder;
export '../src/rust/api/analyze.dart' show AnalyzeResult;
export '../src/rust/api/dsp.dart' show DspHandle, EqBand, EqPreset;
export '../src/rust/api/metadata.dart' show MetadataResult;
export '../src/rust/api/audio_output.dart' show initAudioRingbuf, startFileDecoder, stopFileDecoder;

/// Rust 后端是否已加载
bool rustAvailable = false;

/// 初始化 Rust native 库
Future<void> initRust() async {
  try {
    await RustLib.init();
    rustAvailable = true;
  } catch (_) {
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

// ── DSP ──

Future<dsp.DspHandle> createDsp({
  int sampleRate = 44100,
  int channels = 2,
  double volume = 1.0,
  int bits = 16,
}) {
  return dsp.createDsp(
    sampleRate: sampleRate,
    channels: channels,
    volume: volume,
    bits: bits,
  );
}

Future<void> dspSetEqBand(
  dsp.DspHandle handle,
  int index,
  dsp.EqBand band,
) {
  return dsp.dspSetEqBand(
    handle: handle,
    index: index,
    band: band,
  );
}

Future<void> dspApplyPreset(
  dsp.DspHandle handle,
  dsp.EqPreset preset,
) {
  return dsp.dspApplyPreset(
    handle: handle,
    preset: preset,
  );
}

Future<void> dspSetVolume(
  dsp.DspHandle handle,
  double volume,
) {
  return dsp.dspSetVolume(
    handle: handle,
    volume: volume,
  );
}

Future<void> dspSetCrossfeed(
  dsp.DspHandle handle,
  bool enabled,
) {
  return dsp.dspSetCrossfeed(
    handle: handle,
    enabled: enabled,
  );
}

Future<void> dspSetStereoWidener(
  dsp.DspHandle handle,
  bool enabled,
  double width,
) {
  return dsp.dspSetStereoWidener(
    handle: handle,
    enabled: enabled,
    width: width,
  );
}

Future<List<double>> dspProcess(
  dsp.DspHandle handle,
  List<double> samples,
) async {
  return (await dsp.dspProcess(
    handle: handle,
    samples: samples,
  )).toList();
}

Future<void> dspReset(dsp.DspHandle handle) {
  return dsp.dspReset(handle: handle);
}

// ── 音频输出 ringbuf ──

/// 初始化音频输出 ringbuf
Future<void> initRingbuf() => audio_out.initAudioRingbuf();

/// 启动后台解码线程，直接推入 ringbuf（不经 Dart 中转）
Future<void> startDecoder(String path, {double? seekSecs}) =>
    audio_out.startFileDecoder(path: path, seekSecs: seekSecs);

/// 停止后台解码线程
Future<void> stopDecoder() => audio_out.stopFileDecoder();

// ── 流式解码 ──

/// 创建流式解码器（可选 seek_secs：从指定秒数开始解码）
Future<decode.StreamDecoder> streamDecoderCreate(String path, {double? seekSecs}) {
  return decode.streamDecoderCreate(path: path, seekSecs: seekSecs);
}

/// 获取下一块解码数据
Future<decode.DecodeChunk?> streamDecoderNextChunk(
    decode.StreamDecoder decoder) {
  return decode.streamDecoderNextChunk(decoder: decoder);
}

/// 停止流式解码
Future<void> streamDecoderStop(decode.StreamDecoder decoder) {
  return decode.streamDecoderStop(decoder: decoder);
}
