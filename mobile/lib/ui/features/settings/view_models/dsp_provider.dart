import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../core/providers/repositories.dart';

class DspState {
  final DspSettings dspSettings;
  final List<double> eqValues;
  final String eqPreset;

  DspState({
    DspSettings? dspSettings,
    List<double>? eqValues,
    this.eqPreset = 'Flat',
  }) : dspSettings = dspSettings ?? DspSettings(),
       eqValues = eqValues ?? List.filled(10, 0.0);

  DspState copyWith({
    DspSettings? dspSettings,
    List<double>? eqValues,
    String? eqPreset,
  }) {
    return DspState(
      dspSettings: dspSettings ?? this.dspSettings,
      eqValues: eqValues ?? this.eqValues,
      eqPreset: eqPreset ?? this.eqPreset,
    );
  }
}

class DspNotifier extends Notifier<DspState> {
  @override
  DspState build() => DspState();

  bool get dspAvailable => true;

  Future<List<double>> getSpectrum() =>
      ref.read(audioEngineRepositoryProvider).getSpectrum();

  Future<int> getUnderrunCount() =>
      ref.read(audioEngineRepositoryProvider).getUnderrunCount();

  void toggleDspEnabled() {
    final s = state.dspSettings.copyWith(enabled: !state.dspSettings.enabled);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspEnabled(s.enabled);
    applyDsp();
  }

  void toggleCrossfeed() {
    final s = state.dspSettings.copyWith(
      crossfeed: !state.dspSettings.crossfeed,
    );
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspCrossfeed(s.crossfeed);
    applyDsp();
  }

  void toggleWidener() {
    final s = state.dspSettings.copyWith(widener: !state.dspSettings.widener);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspWidener(s.widener);
    applyDsp();
  }

  void toggleLimiter() {
    final s = state.dspSettings.copyWith(limiter: !state.dspSettings.limiter);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspLimiter(s.limiter);
    applyDsp();
  }

  void toggleDither() {
    final s = state.dspSettings.copyWith(dither: !state.dspSettings.dither);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspDither(s.dither);
    applyDsp();
  }

  /// 把当前 DSP 设置同步到引擎。
  /// enabled 为总开关：关闭时全部子开关置 false，打开时恢复各子开关状态。
  Future<void> applyDsp() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final dsp = state.dspSettings;
    final on = dsp.enabled;
    try {
      await engineRepo.setCrossfeed(on && dsp.crossfeed);
      await engineRepo.setStereoWidener(on && dsp.widener, 0.5);
      await engineRepo.setLimiter(on && dsp.limiter);
      await engineRepo.setDither(on && dsp.dither);
    } catch (e) {
      debugPrint('[DSP] 应用设置失败: $e');
    }
  }

  void loadDspPrefs() {
    final prefs = ref.read(preferencesRepositoryProvider);
    state = state.copyWith(
      dspSettings: DspSettings(
        enabled: prefs.dspEnabled,
        crossfeed: prefs.dspCrossfeed,
        widener: prefs.dspWidener,
        limiter: prefs.dspLimiter,
        dither: prefs.dspDither,
      ),
    );
  }

  // ── 10 段参量 EQ ──

  /// EQ 频段中心频率（Hz），与 audio-core `preset_bands` 一致。
  static const List<double> eqFrequencies = [
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
  ];

  /// EQ 默认 Q 值（与 audio-core 一致）。
  static const double eqDefaultQ = 1.41;

  /// 预设增益表（dB）——与 audio-core `dsp::preset_bands` 逐值对齐，
  /// 引擎是单一事实来源：UI 显示的曲线即听到的曲线。
  static const Map<String, List<double>> eqPresets = {
    'Flat':       [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Rock':       [-1.2, -1.2, -2.4, -6.5, -7.4, -5.8, -2.6, -0.7, 0.0, 0.0],
    'Pop':        [-5.0, -5.0, -2.4, -1.4, -1.2, -2.2, -4.8, -5.3, -5.3, -5.0],
    'Dance':      [-0.5, -0.5, -1.4, -3.4, -4.3, -4.3, -6.7, -7.2, -7.2, -4.3],
    'Classical':  [-4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -7.2, -7.2, -8.2],
    'Soft':       [-2.4, -2.4, -3.6, -4.8, -5.3, -4.8, -2.6, -1.0, -0.5, 0.5],
    'Full Bass':  [-0.5, -0.5, -0.5, -0.5, -1.9, -3.6, -6.0, -7.7, -8.4, -8.6],
    'Full Treble':[-8.2, -8.2, -8.2, -8.2, -6.0, -3.1, 0.0, 1.9, 1.9, 2.4],
    'Techno':     [-1.2, -1.2, -1.9, -4.1, -6.5, -6.2, -4.1, -1.2, -0.5, -0.7],
    'Vocals':     [-3.0, -3.0, -2.0, -0.5, 1.0, 2.5, 3.0, 1.5, 0.0, 0.0],
  };

  /// UI 预设名 → Rust 预设名（engine_apply_preset 接受的键）。
  static const Map<String, String> _rustPresetNames = {
    'Flat': 'flat',
    'Rock': 'rock',
    'Pop': 'pop',
    'Dance': 'dance',
    'Classical': 'classical',
    'Soft': 'soft',
    'Full Bass': 'full_bass',
    'Full Treble': 'full_treble',
    'Techno': 'techno',
    'Vocals': 'vocals',
  };

  /// 应用 EQ 预设：更新本地曲线并下发引擎。
  Future<void> applyEqPreset(String name) async {
    final gains = eqPresets[name];
    if (gains == null) return;
    state = state.copyWith(eqPreset: name, eqValues: List.from(gains));
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    try {
      await engineRepo.applyPreset(_rustPresetNames[name] ?? name.toLowerCase());
    } catch (e) {
      debugPrint('[EQ] applyPreset 失败: $e');
    }
  }

  /// 手动调整单个频段增益：更新本地曲线并下发引擎，取消预设高亮。
  Future<void> setEqBand(int index, double gainDb) async {
    if (index < 0 || index >= state.eqValues.length) return;
    final values = List<double>.from(state.eqValues);
    values[index] = gainDb;
    // 手动调整后不再是纯预设（eqPreset 置空）
    state = state.copyWith(eqValues: values, eqPreset: '');
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    try {
      await engineRepo.setPeqBand(
        index,
        eqFrequencies[index],
        gainDb,
        eqDefaultQ,
      );
    } catch (e) {
      debugPrint('[EQ] setPeqBand 失败: $e');
    }
  }
}

final dspProvider = NotifierProvider<DspNotifier, DspState>(DspNotifier.new);
