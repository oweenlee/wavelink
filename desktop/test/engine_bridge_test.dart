import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/services/engine.dart';

/// 桥接层集成测试：加载真实 Rust 动态库，验证本轮补齐的 DSP / 采样率桥函数
/// 经 Dart→FRB→Rust 全链路可调用且不 panic。仅验证链路通畅（不依赖音源/音频设备）：
/// 未 init 时 getter 返回安全默认值，setter 为空操作。
///
/// 需要先用 `cargo build -p wavelink_desktop` 产出 dylib；缺失则跳过（不视为失败）。
void main() {
  test('bridge: new DSP / sample-rate functions callable via FFI', () async {
    final dylib = _resolveDylib();
    if (dylib == null) {
      markTestSkipped(
          'wavelink_desktop dylib 未构建，先运行 `cargo build -p wavelink_desktop`');
    }
    final engine = await Engine.load(dylibPath: dylib);
    expect(engine, isNotNull, reason: '动态库应成功加载');

    // 未 init 时安全默认值
    expect(await engine!.outputSampleRate(), 0);
    expect(await engine.underrunCount(), 0);

    // 本轮补齐的全部桥函数：应可调用且不抛
    await engine.setStereoWidener(true, 0.5);
    await engine.setCrossfeed(true);
    await engine.setLimiter(true);
    await engine.setDither(true);
    await engine.setNoiseShaping(true);
    await engine.setReplaygainGain(-3.0);
    await engine.setSpeed(1.25);
    await engine.applyPreset('flat');
    await engine.setAutoEq(null);
    await engine.setOutputSampleRate(48000);
    await engine.clearIr();
    await engine.loadIr('/tmp/ir.wav');
    await engine.setPeqBand(0, 1000.0, -3.0, 1.0);

    // 设备枚举不抛、返回列表
    final devs = await engine.enumerateDevices();
    expect(devs, isA<List<String>>());
  });
}

String? _resolveDylib() {
  final candidates = [
    '../target/debug/libwavelink_desktop.dylib',
    '../target/release/libwavelink_desktop.dylib',
    'target/debug/libwavelink_desktop.dylib',
    'target/release/libwavelink_desktop.dylib',
    'rust/target/debug/libwavelink_desktop.dylib',
    '/Users/qin/Desktop/wavelink/target/debug/libwavelink_desktop.dylib',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
