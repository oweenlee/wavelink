import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_settings_provider.dart';
import 'player_providers.dart';

/// 音频输出设备热插拔监听（Dart 侧轮询实现）。
///
/// cpal 0.15 无跨平台稳定的 device-change 事件 API，故每 2s 枚举一次设备
/// 列表对比快照（枚举开销极小，仅字符数组对比）。职责：
/// 1. 设备插入/拔出后刷新 `audioSettingsProvider.devices`（设置页下拉即时更新）；
/// 2. 用户选中的设备被拔掉时自动回退「系统默认」并提示，
///    避免音频继续流向已消失设备导致无声（core 侧 stream_failed 断流回退
///    是最后防线；这里在回退后即时把选择落地到持久化）。
class DeviceWatcher {
  DeviceWatcher(this._container);

  final ProviderContainer _container;
  Timer? _timer;
  List<String> _lastDevices = const [];

  static const _interval = Duration(seconds: 2);

  /// 启动轮询（引擎就绪后由 main 调用；引擎未 init 时自动跳过）。
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => unawaited(_tick()));
  }

  /// 单测入口：直接执行一轮设备检查（不依赖 Timer）。
  @visibleForTesting
  Future<void> tickForTest() => _tick();

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final player = _container.read(playerProvider.notifier);
    if (player.engine == null) return;
    final engine = player.engine;
    if (engine == null) return;
    List<String> devices;
    try {
      devices = await engine.enumerateDevices();
    } catch (_) {
      return; // 引擎轮询窗口期（reinitialize 等）失败静默跳过
    }
    if (devices.isEmpty && _lastDevices.isEmpty) return;
    final changed = !_sameSet(devices, _lastDevices);
    _lastDevices = devices;
    if (!changed) return;

    final audio = _container.read(audioSettingsProvider);
    // 设备列表变化：刷新设置页下拉；选中设备消失时回退系统默认。
    if (!devices.contains(audio.selectedDevice) &&
        audio.selectedDevice != null) {
      await _container
          .read(audioSettingsProvider.notifier)
          .selectDevice(null);
      player.notifyUser('输出设备「${audio.selectedDevice}」已断开，已切回系统默认');
    }
    await _container.read(audioSettingsProvider.notifier).refreshDevices();
  }

  static bool _sameSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final bs = b.toSet();
    return a.every(bs.contains);
  }
}