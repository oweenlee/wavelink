import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine.dart';
import 'player_providers.dart';

// ═══════════════════════════ 音频输出设置 ═══════════════════════════
//
// 对齐 mobile `features/settings/view_models/` 的 Notifier 模式：
// 不可变 State + copyWith + setter「更新状态 → 持久化 → 下发引擎」三步走。
// 视图（screens/settings.dart）只负责布局与交互反馈，不再持有业务状态。
//
// 持久化 key 与 PlayerNotifier.init 的 `_restoreAudioSettings` 同源：
// outputDevice / exclusiveMode / outputSampleRate / engine.*。

/// 音频输出状态。
class AudioSettingsState {
  const AudioSettingsState({
    this.devices = const [],
    this.selectedDevice,
    this.exclusive = false,
    this.actualSampleRate,
    this.sampleRatePref = 44100,
    this.bitPerfect = false,
    this.autoSampleRate = false,
    this.crossfadeMs = 0,
  });

  /// 可选输出设备列表。
  final List<String> devices;

  /// null = 系统默认。
  final String? selectedDevice;
  final bool exclusive;
  final int? actualSampleRate;

  /// 持久化的输出采样率设置值（SR 输入框回显用）。
  final int sampleRatePref;
  final bool bitPerfect;
  final bool autoSampleRate;
  final double crossfadeMs;

  AudioSettingsState copyWith({
    List<String>? devices,
    Object? selectedDevice = _sentinel,
    bool? exclusive,
    Object? actualSampleRate = _sentinel,
    int? sampleRatePref,
    bool? bitPerfect,
    bool? autoSampleRate,
    double? crossfadeMs,
  }) {
    return AudioSettingsState(
      devices: devices ?? this.devices,
      selectedDevice: identical(selectedDevice, _sentinel)
          ? this.selectedDevice
          : selectedDevice as String?,
      exclusive: exclusive ?? this.exclusive,
      actualSampleRate: identical(actualSampleRate, _sentinel)
          ? this.actualSampleRate
          : actualSampleRate as int?,
      sampleRatePref: sampleRatePref ?? this.sampleRatePref,
      bitPerfect: bitPerfect ?? this.bitPerfect,
      autoSampleRate: autoSampleRate ?? this.autoSampleRate,
      crossfadeMs: crossfadeMs ?? this.crossfadeMs,
    );
  }

  static const Object _sentinel = Object();
}

/// 音频输出设置 Notifier。
class AudioSettingsNotifier extends Notifier<AudioSettingsState> {
  Engine? get _engine => ref.read(playerProvider.notifier).engine;

  @override
  AudioSettingsState build() {
    // 异步恢复持久化值 + 拉取设备列表（build 同步返回默认值，与 mobile 一致）。
    Future.microtask(_restore);
    return const AudioSettingsState();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final e = _engine;
    List<String> devices = const [];
    try {
      devices = await e?.enumerateDevices() ?? const [];
    } catch (_) {}
    final actualSr = await _trySampleRate();
    final persisted = AudioSettingsState(
      devices: devices,
      selectedDevice: p.getString('outputDevice'),
      exclusive: p.getBool('exclusiveMode') ?? false,
      actualSampleRate: actualSr,
      sampleRatePref: p.getInt('outputSampleRate') ?? 44100,
      bitPerfect: p.getBool('engine.bitPerfect') ?? false,
      autoSampleRate: p.getBool('engine.autoSampleRate') ?? false,
      crossfadeMs: (p.getInt('engine.crossfadeMs') ?? 0).toDouble(),
    );
    // 只在 provider 仍存活时落状态（页面关闭即销毁，避免 use after dispose）。
    if (ref.mounted) state = persisted;
  }

  Future<int?> _trySampleRate() async {
    try {
      return await _engine?.outputSampleRate();
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshDevices() async {
    try {
      final d = await _engine?.enumerateDevices() ?? const [];
      state = state.copyWith(devices: d);
    } catch (_) {}
  }

  Future<void> refreshActualSampleRate() async {
    state = state.copyWith(actualSampleRate: await _trySampleRate());
  }

  /// 选设备：null = 系统默认（持久化层面为删除 key）。
  Future<void> selectDevice(String? name) async {
    state = state.copyWith(selectedDevice: name);
    final p = await SharedPreferences.getInstance();
    if (name == null) {
      await p.remove('outputDevice');
    } else {
      await p.setString('outputDevice', name);
    }
    await _engine?.setOutputDevice(name);
  }

  /// 切独占模式：重启引擎，返回错误信息（null = 成功）供视图提示。
  Future<String?> setExclusive(bool v) async {
    state = state.copyWith(exclusive: v);
    (await SharedPreferences.getInstance()).setBool('exclusiveMode', v);
    final err = await _engine?.reinitialize(exclusiveMode: v);
    await refreshActualSampleRate();
    return err;
  }

  /// 应用输出采样率。
  Future<void> applySampleRate(int hz) async {
    state = state.copyWith(sampleRatePref: hz);
    (await SharedPreferences.getInstance()).setInt('outputSampleRate', hz);
    await _engine?.setOutputSampleRate(hz);
    await refreshActualSampleRate();
  }

  Future<String?> setBitPerfect(bool v) async {
    state = state.copyWith(bitPerfect: v);
    (await SharedPreferences.getInstance()).setBool('engine.bitPerfect', v);
    final err = await _engine?.reinitialize(bitPerfect: v);
    await refreshActualSampleRate();
    return err;
  }

  Future<String?> setAutoSampleRate(bool v) async {
    state = state.copyWith(autoSampleRate: v);
    (await SharedPreferences.getInstance()).setBool('engine.autoSampleRate', v);
    final err = await _engine?.reinitialize(autoSampleRate: v);
    await refreshActualSampleRate();
    return err;
  }

  /// 更新交叉淡入淡出（拖动中实时调用，不落盘）。
  Future<void> setCrossfade(double ms) async {
    state = state.copyWith(crossfadeMs: ms);
  }

  /// 滑块松手（onChangeEnd）时持久化，避免拖动中每帧写磁盘。
  Future<void> persistCrossfade() async {
    (await SharedPreferences.getInstance())
        .setInt('engine.crossfadeMs', state.crossfadeMs.round());
  }
}

final audioSettingsProvider =
    NotifierProvider<AudioSettingsNotifier, AudioSettingsState>(
        AudioSettingsNotifier.new);
