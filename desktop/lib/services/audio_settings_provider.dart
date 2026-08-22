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
  /// reinitialize 会 deinit+重建引擎，播放中切换会打断播放。
  /// 统一处理：记录播放状态 → 重建 → 成功则重播当前曲目并恢复原位置。
  Future<String?> _reinitWithPlaybackResume({
    bool exclusiveMode = false,
    bool? bitPerfect,
    bool? autoSampleRate,
  }) async {
    final player = ref.read(playerProvider.notifier);
    final st = ref.read(playerProvider);
    final wasPlaying = st.playing && st.currentTrack != null;
    final err = await _engine?.reinitialize(
      exclusiveMode: exclusiveMode,
      bitPerfect: bitPerfect,
      autoSampleRate: autoSampleRate,
    );
    await refreshActualSampleRate();
    if (err == null && wasPlaying) {
      await player.replayCurrentTrack();
    }
    return err;
  }

  Future<String?> setExclusive(bool v) async {
    state = state.copyWith(exclusive: v);
    (await SharedPreferences.getInstance()).setBool('exclusiveMode', v);
    // 播放中切换会打断播放，需用户确认场景见 UI 层
    return _reinitWithPlaybackResume(exclusiveMode: v);
  }

  /// 应用输出采样率。播放中切换时自动重播当前曲目并恢复原位置：
  /// 引擎会立即重建输出流，但解码管线仍按旧目标速率生产样本，
  /// 不重启会导致变速变调与 underrun 坏帧。
  Future<void> applySampleRate(int hz) async {
    final player = ref.read(playerProvider.notifier);
    final st = ref.read(playerProvider);
    final wasPlaying = st.playing && st.currentTrack != null;
    state = state.copyWith(sampleRatePref: hz);
    (await SharedPreferences.getInstance()).setInt('outputSampleRate', hz);
    await _engine?.setOutputSampleRate(hz);
    await refreshActualSampleRate();
    if (wasPlaying) {
      await player.replayCurrentTrack();
    }
  }

  Future<String?> setBitPerfect(bool v) async {
    state = state.copyWith(bitPerfect: v);
    (await SharedPreferences.getInstance()).setBool('engine.bitPerfect', v);
    return _reinitWithPlaybackResume(bitPerfect: v);
  }

  Future<String?> setAutoSampleRate(bool v) async {
    state = state.copyWith(autoSampleRate: v);
    (await SharedPreferences.getInstance()).setBool('engine.autoSampleRate', v);
    return _reinitWithPlaybackResume(autoSampleRate: v);
  }

  /// 更新交叉淡入淡出（拖动中实时调用，不落盘）。
  Future<void> setCrossfade(double ms) async {
    state = state.copyWith(crossfadeMs: ms);
  }

  /// 滑块松手（onChangeEnd）时持久化，避免拖动中每帧写磁盘。
  /// 同时同步引擎快照：引擎无运行时 crossfade 命令，改动重启后生效，
  /// 但后续 reinitialize（切独占等）必须带上新值，否则被静默回滚。
  Future<void> persistCrossfade() async {
    (await SharedPreferences.getInstance())
        .setInt('engine.crossfadeMs', state.crossfadeMs.round());
    _engine?.updateCrossfadePref(state.crossfadeMs.round());
  }

  /// 恢复音频输出默认值（系统默认设备/共享模式/44100/无交叉淡化），
  /// 一次 reinitialize 下发，避免多次重启引擎。
  Future<String?> resetOutput() async {
    final p = await SharedPreferences.getInstance();
    await Future.wait([
      p.setBool('exclusiveMode', false),
      p.setBool('engine.bitPerfect', false),
      p.setBool('engine.autoSampleRate', false),
      p.setInt('outputSampleRate', 44100),
      p.setInt('engine.crossfadeMs', 0),
      p.remove('outputDevice'),
    ]);
    final err = await _engine?.reinitialize(
      exclusiveMode: false,
      bitPerfect: false,
      autoSampleRate: false,
    );
    await _engine?.setOutputSampleRate(44100);
    await refreshActualSampleRate();
    state = state.copyWith(
      exclusive: false,
      bitPerfect: false,
      autoSampleRate: false,
      sampleRatePref: 44100,
      crossfadeMs: 0,
      selectedDevice: null,
    );
    return err;
  }
}

final audioSettingsProvider =
    NotifierProvider<AudioSettingsNotifier, AudioSettingsState>(
        AudioSettingsNotifier.new);
