import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../core/providers/repositories.dart';
import '../../../../data/services/log.dart';

class DspState {
  final DspSettings dspSettings;
  final List<double> eqValues;
  final String eqPreset;

  /// AutoEQ 耳机校正型号（null = 关闭）
  final String? autoEqModel;

  DspState({
    DspSettings? dspSettings,
    List<double>? eqValues,
    this.eqPreset = 'Flat',
    this.autoEqModel,
  }) : dspSettings = dspSettings ?? DspSettings(),
       eqValues = eqValues ?? List.filled(10, 0.0);

  DspState copyWith({
    DspSettings? dspSettings,
    List<double>? eqValues,
    String? eqPreset,
    Object? autoEqModel = _sentinel,
  }) {
    return DspState(
      dspSettings: dspSettings ?? this.dspSettings,
      eqValues: eqValues ?? this.eqValues,
      eqPreset: eqPreset ?? this.eqPreset,
      autoEqModel: identical(autoEqModel, _sentinel)
          ? this.autoEqModel
          : autoEqModel as String?,
    );
  }

  static const Object _sentinel = Object();
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

  void toggleNoiseShaping() {
    final s = state.dspSettings.copyWith(
      noiseShaping: !state.dspSettings.noiseShaping,
    );
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspNoiseShaping(s.noiseShaping);
    applyDsp();
  }

  // ── AutoEQ 耳机校正 ──

  /// 档案目录（型号名列表，设置页选择用）
  Future<List<String>> getAutoEqCatalog() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return const [];
    try {
      return await engineRepo.autoEqCatalog();
    } catch (e) {
      Log.e('AutoEQ', '获取目录失败: $e');
      return const [];
    }
  }

  /// 应用/清除耳机校正档案（null = 关闭）：持久化 + 下发引擎。
  /// 与手动 EQ 互斥：应用档案时引擎整组替换 PEQ；关闭档案时恢复已持久化
  /// 的手动 EQ 曲线（全零时为 no-op）。
  void setAutoEq(String? model) {
    state = state.copyWith(autoEqModel: model);
    ref.read(preferencesRepositoryProvider).setAutoEqModel(model);
    applyDsp();
    if (model == null) applyEqToEngine();
  }

  /// 手动 EQ 操作（拖滑块/应用预设）前调用：档案生效则先清除——互斥，
  /// 最近操作赢。await 引擎命令保证「档案清除恢复平坦」先于手动频段
  /// 写入生效（命令通道按序执行）。
  Future<void> _clearAutoEqIfActive() async {
    if (state.autoEqModel == null) return;
    state = state.copyWith(autoEqModel: null);
    ref.read(preferencesRepositoryProvider).setAutoEqModel(null);
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    await engineRepo.setAutoEq(null);
  }

  /// 把当前 DSP 设置同步到引擎。
  /// enabled 为总开关：关闭时全部子开关置 false，打开时恢复各子开关状态。
  /// AutoEQ 独立于总开关（耳机校正不属于“音效渲染”范畴）。
  Future<void> applyDsp() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final dsp = state.dspSettings;
    final on = dsp.enabled;
    // async gap 后 provider 可能已 disposed，先取快照避免访问 ref/state
    final autoEq = state.autoEqModel;
    try {
      await engineRepo.setCrossfeed(on && dsp.crossfeed);
      await engineRepo.setStereoWidener(on && dsp.widener, 0.5);
      await engineRepo.setLimiter(on && dsp.limiter);
      await engineRepo.setDither(on && dsp.dither);
      // 噪声整形仅在 dither 生效时有意义，随 dither 门控
      await engineRepo.setNoiseShaping(on && dsp.noiseShaping);
      await engineRepo.setAutoEq(autoEq);
    } catch (e) {
      Log.e('DSP', '应用设置失败: $e');
    }
  }

  void loadDspPrefs() {
    final prefs = ref.read(preferencesRepositoryProvider);
    final eqGains = prefs.eqGains;
    final eqPreset = prefs.eqPreset;
    // 从未保存过 EQ（无预设且无手动曲线）：保持默认 Flat 高亮
    final hasSavedEq =
        eqPreset.isNotEmpty ||
        (eqGains.length == 10 && eqGains.any((g) => g != 0.0));
    state = state.copyWith(
      dspSettings: DspSettings(
        enabled: prefs.dspEnabled,
        crossfeed: prefs.dspCrossfeed,
        widener: prefs.dspWidener,
        limiter: prefs.dspLimiter,
        dither: prefs.dspDither,
        noiseShaping: prefs.dspNoiseShaping,
      ),
      autoEqModel: prefs.autoEqModel,
      eqPreset: hasSavedEq ? eqPreset : null,
      eqValues: hasSavedEq && eqGains.length == 10 ? eqGains : null,
    );
  }

  /// 把持久化的 EQ 曲线下发到引擎（启动时引擎初始化完成后调用；
  /// 预设走 applyPreset 保证与 audio-core 单一事实来源一致，
  /// 手动曲线逐频段下发）。
  Future<void> applyEqToEngine() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    // async gap 后 provider 可能已 disposed，先取快照避免访问 ref/state
    final preset = state.eqPreset;
    final gains = state.eqValues;
    try {
      final rustName = _rustPresetNames[preset];
      if (rustName != null) {
        await engineRepo.applyPreset(rustName);
        return;
      }
      // 非预设（手动曲线或从未保存）：全零时无需下发
      if (gains.every((g) => g == 0.0)) return;
      for (var i = 0; i < gains.length && i < eqFrequencies.length; i++) {
        await engineRepo.setPeqBand(i, eqFrequencies[i], gains[i], eqDefaultQ);
      }
    } catch (e) {
      Log.e('EQ', '启动恢复 EQ 失败: $e');
    }
  }

  // ── 10 段参量 EQ ──

  /// EQ 频段中心频率（Hz），与 audio-core `preset_bands` 一致。
  static const List<double> eqFrequencies = [
    31,
    62,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];

  /// EQ 默认 Q 值（与 audio-core 一致）。
  static const double eqDefaultQ = 1.41;

  /// 预设增益表（dB）——与 audio-core `dsp::preset_bands` 逐值对齐，
  /// 引擎是单一事实来源：UI 显示的曲线即听到的曲线。
  static const Map<String, List<double>> eqPresets = {
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Rock': [-1.2, -1.2, -2.4, -6.5, -7.4, -5.8, -2.6, -0.7, 0.0, 0.0],
    'Pop': [-5.0, -5.0, -2.4, -1.4, -1.2, -2.2, -4.8, -5.3, -5.3, -5.0],
    'Dance': [-0.5, -0.5, -1.4, -3.4, -4.3, -4.3, -6.7, -7.2, -7.2, -4.3],
    'Classical': [-4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -7.2, -7.2, -8.2],
    'Soft': [-2.4, -2.4, -3.6, -4.8, -5.3, -4.8, -2.6, -1.0, -0.5, 0.5],
    'Full Bass': [-0.5, -0.5, -0.5, -0.5, -1.9, -3.6, -6.0, -7.7, -8.4, -8.6],
    'Full Treble': [-8.2, -8.2, -8.2, -8.2, -6.0, -3.1, 0.0, 1.9, 1.9, 2.4],
    'Techno': [-1.2, -1.2, -1.9, -4.1, -6.5, -6.2, -4.1, -1.2, -0.5, -0.7],
    'Vocals': [-3.0, -3.0, -2.0, -0.5, 1.0, 2.5, 3.0, 1.5, 0.0, 0.0],
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

  /// 应用 EQ 预设：更新本地曲线、持久化并下发引擎。
  Future<void> applyEqPreset(String name) async {
    final gains = eqPresets[name];
    if (gains == null) return;
    await _clearAutoEqIfActive();
    state = state.copyWith(eqPreset: name, eqValues: List.from(gains));
    ref
        .read(preferencesRepositoryProvider)
        .setEqState(preset: name, gains: gains);
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    try {
      await engineRepo.applyPreset(
        _rustPresetNames[name] ?? name.toLowerCase(),
      );
    } catch (e) {
      Log.e('EQ', 'applyPreset 失败: $e');
    }
  }

  /// 手动调整单个频段增益：更新本地曲线、持久化并下发引擎，取消预设高亮。
  Future<void> setEqBand(int index, double gainDb) async {
    if (index < 0 || index >= state.eqValues.length) return;
    await _clearAutoEqIfActive();
    final values = List<double>.from(state.eqValues);
    values[index] = gainDb;
    // 手动调整后不再是纯预设（eqPreset 置空）
    state = state.copyWith(eqValues: values, eqPreset: '');
    ref
        .read(preferencesRepositoryProvider)
        .setEqState(preset: '', gains: values);
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
      Log.e('EQ', 'setPeqBand 失败: $e');
    }
  }
}

final dspProvider = NotifierProvider<DspNotifier, DspState>(DspNotifier.new);
