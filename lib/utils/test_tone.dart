import 'dart:math' as math;
import 'dart:typed_data';

/// 生成 PCM f32 测试音（C大调和弦 + 泛音）
/// 返回 (samples, sampleRate, channels)
(Float32List, int, int) generateTestTone({double durationSec = 8.0}) {
  const sampleRate = 44100;
  const channels = 2;
  final totalSamples = (sampleRate * durationSec).toInt() * channels;
  final result = Float32List(totalSamples);
  final twoPi = 2 * math.pi;

  // C4(261.63) + E4(329.63) + G4(392.00) — C大调三和弦
  const freqs = <double>[261.63, 329.63, 392.00, 523.25, 659.25];
  const amps = <double>[0.25, 0.20, 0.20, 0.15, 0.10];

  for (int i = 0; i < totalSamples ~/ channels; i++) {
    final t = i / sampleRate;
    // 淡入淡出（前 50ms + 后 100ms）
    double env = 1.0;
    if (i < 2205) {
      env = i / 2205.0; // ~50ms fade-in
    } else if (i > totalSamples ~/ channels - 4410) {
      env = (totalSamples ~/ channels - i) / 4410.0; // ~100ms fade-out
    }

    double sample = 0;
    for (int h = 0; h < freqs.length; h++) {
      sample += amps[h] * math.sin(twoPi * freqs[h] * t);
    }
    sample *= env;

    // 左声道稍偏左，右声道稍偏右
    result[i * channels] = sample * 0.9;
    result[i * channels + 1] = sample;
  }

  return (result, sampleRate, channels);
}
