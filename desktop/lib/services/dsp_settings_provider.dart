import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine.dart';
import 'player_providers.dart';

// ═══════════════════════════ DSP 效果设置 ═══════════════════════════
//
// 对齐 mobile `features/settings/view_models/dsp_provider.dart`：
// 不可变 State + copyWith（null 字段用哨兵区分）+ setter 三步走
// （更新状态 → 持久化 → 下发引擎）。持久化 key：dsp.*。

/// DSP 效果状态。
class DspSettingsState {
  const DspSettingsState({
    this.widenerOn = false,
    this.widenerWidth = 0.5,
    this.crossfeed = false,
    this.limiter = false,
    this.dither = false,
    this.noiseShaping = false,
    this.gain = 0,
    this.speed = 1.0,
    this.preset = 'flat',
    this.autoEq = '',
    this.irPath = '',
  });

  final bool widenerOn;
  final double widenerWidth;
  final bool crossfeed;
  final bool limiter;
  final bool dither;
  final bool noiseShaping;
  final double gain;
  final double speed;
  final String preset;
  final String autoEq;
  final String irPath;

  DspSettingsState copyWith({
    bool? widenerOn,
    double? widenerWidth,
    bool? crossfeed,
    bool? limiter,
    bool? dither,
    bool? noiseShaping,
    double? gain,
    double? speed,
    String? preset,
    Object? autoEq = _sentinel,
    Object? irPath = _sentinel,
  }) {
    return DspSettingsState(
      widenerOn: widenerOn ?? this.widenerOn,
      widenerWidth: widenerWidth ?? this.widenerWidth,
      crossfeed: crossfeed ?? this.crossfeed,
      limiter: limiter ?? this.limiter,
      dither: dither ?? this.dither,
      noiseShaping: noiseShaping ?? this.noiseShaping,
      gain: gain ?? this.gain,
      speed: speed ?? this.speed,
      preset: preset ?? this.preset,
      autoEq:
          identical(autoEq, _sentinel) ? this.autoEq : autoEq as String,
      irPath: identical(irPath, _sentinel) ? this.irPath : irPath as String,
    );
  }

  static const Object _sentinel = Object();
}

/// DSP 效果设置 Notifier。
class DspSettingsNotifier extends Notifier<DspSettingsState> {
  Engine? get _engine => ref.read(playerProvider.notifier).engine;

  @override
  DspSettingsState build() {
    Future.microtask(_restore);
    return const DspSettingsState();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    state = DspSettingsState(
      widenerOn: p.getBool('dsp.widener') ?? false,
      widenerWidth: p.getDouble('dsp.widenerWidth') ?? 0.5,
      crossfeed: p.getBool('dsp.crossfeed') ?? false,
      limiter: p.getBool('dsp.limiter') ?? false,
      dither: p.getBool('dsp.dither') ?? false,
      noiseShaping: p.getBool('dsp.noiseShaping') ?? false,
      gain: p.getDouble('dsp.gain') ?? 0,
      speed: p.getDouble('dsp.speed') ?? 1.0,
      preset: p.getString('dsp.preset') ?? 'flat',
      autoEq: p.getString('dsp.autoEq') ?? '',
      irPath: p.getString('dsp.irPath') ?? '',
    );
  }

  Future<void> _saveBool(String k, bool v) =>
      SharedPreferences.getInstance().then((p) => p.setBool(k, v));

  Future<void> _saveDouble(String k, double v) =>
      SharedPreferences.getInstance().then((p) => p.setDouble(k, v));

  Future<void> _saveString(String k, String? v) =>
      SharedPreferences.getInstance().then((p) =>
          v == null ? p.remove(k) : p.setString(k, v));

  // ── 空间效果 ──

  void toggleWidener(bool v) {
    state = state.copyWith(widenerOn: v);
    _saveBool('dsp.widener', v);
    _engine?.setStereoWidener(v, state.widenerWidth);
  }

  void setWidenerWidth(double v) {
    state = state.copyWith(widenerWidth: v);
    if (state.widenerOn) _engine?.setStereoWidener(true, v);
  }

  void setCrossfeed(bool v) {
    state = state.copyWith(crossfeed: v);
    _saveBool('dsp.crossfeed', v);
    _engine?.setCrossfeed(v);
  }

  // ── 动态处理 ──

  void setLimiter(bool v) {
    state = state.copyWith(limiter: v);
    _saveBool('dsp.limiter', v);
    _engine?.setLimiter(v);
  }

  void setDither(bool v) {
    state = state.copyWith(dither: v);
    _saveBool('dsp.dither', v);
    _engine?.setDither(v);
  }

  void setNoiseShaping(bool v) {
    state = state.copyWith(noiseShaping: v);
    _saveBool('dsp.noiseShaping', v);
    _engine?.setNoiseShaping(v);
  }

  // ── 增益与速度 ──

  void setGain(double v) {
    state = state.copyWith(gain: v);
    _engine?.setReplaygainGain(v);
  }

  void setSpeed(double v) {
    state = state.copyWith(speed: v);
    _engine?.setSpeed(v);
  }

  /// 滑块松手（onChangeEnd）时统一持久化，避免拖动中每帧写磁盘。
  Future<void> persistSliders() async {
    await _saveDouble('dsp.widenerWidth', state.widenerWidth);
    await _saveDouble('dsp.gain', state.gain);
    await _saveDouble('dsp.speed', state.speed);
  }

  // ── 均衡器 ──

  void applyPreset(String name) {
    state = state.copyWith(preset: name);
    _saveString('dsp.preset', name);
    _engine?.applyPreset(name);
  }

  /// null = 关闭 AutoEQ。
  void setAutoEq(String? model) {
    state = state.copyWith(autoEq: model ?? '');
    _saveString('dsp.autoEq', model);
    _engine?.setAutoEq(model);
  }

  Future<List<String>> autoEqCatalog() async {
    try {
      return await _engine?.autoEqCatalog() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  // ── 房间校正 ──

  Future<void> loadIr(String path) async {
    await _engine?.loadIr(path);
    state = state.copyWith(irPath: path);
    _saveString('dsp.irPath', path);
  }

  void clearIr() {
    state = state.copyWith(irPath: '');
    _saveString('dsp.irPath', null);
    _engine?.clearIr();
  }
}

final dspSettingsProvider =
    NotifierProvider<DspSettingsNotifier, DspSettingsState>(
        DspSettingsNotifier.new);
