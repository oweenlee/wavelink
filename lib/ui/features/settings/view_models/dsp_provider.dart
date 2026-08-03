import 'package:flutter/material.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../../data/repositories/audio_engine_repository.dart';
import '../../../../data/repositories/preferences_repository.dart';

class DspProvider extends ChangeNotifier {
  DspProvider({required this._engineRepo, required this._prefsRepo});

  final AudioEngineRepository _engineRepo;
  final PreferencesRepository _prefsRepo;
  DspSettings _dspSettings = DspSettings();

  DspSettings get dspSettings => _dspSettings;
  bool get dspAvailable => true;

  Future<List<double>> getSpectrum() => _engineRepo.getSpectrum();
  Future<int> getUnderrunCount() => _engineRepo.getUnderrunCount();

  void toggleDspEnabled() {
    _dspSettings = _dspSettings.copyWith(enabled: !_dspSettings.enabled);
    _prefsRepo.setDspEnabled(_dspSettings.enabled);
    applyDsp();
    notifyListeners();
  }

  void toggleCrossfeed() {
    _dspSettings = _dspSettings.copyWith(crossfeed: !_dspSettings.crossfeed);
    _prefsRepo.setDspCrossfeed(_dspSettings.crossfeed);
    applyDsp();
    notifyListeners();
  }

  void toggleWidener() {
    _dspSettings = _dspSettings.copyWith(widener: !_dspSettings.widener);
    _prefsRepo.setDspWidener(_dspSettings.widener);
    applyDsp();
    notifyListeners();
  }

  void toggleLimiter() {
    _dspSettings = _dspSettings.copyWith(limiter: !_dspSettings.limiter);
    _prefsRepo.setDspLimiter(_dspSettings.limiter);
    applyDsp();
    notifyListeners();
  }

  void toggleDither() {
    _dspSettings = _dspSettings.copyWith(dither: !_dspSettings.dither);
    _prefsRepo.setDspDither(_dspSettings.dither);
    applyDsp();
    notifyListeners();
  }

  /// 把当前 DSP 设置同步到引擎。
  /// enabled 为总开关：关闭时全部子开关置 false，打开时恢复各子开关状态。
  Future<void> applyDsp() async {
    if (!_engineRepo.rustAvailable) return;
    final on = _dspSettings.enabled;
    try {
      await _engineRepo.setCrossfeed(on && _dspSettings.crossfeed);
      await _engineRepo.setStereoWidener(on && _dspSettings.widener, 0.5);
      await _engineRepo.setLimiter(on && _dspSettings.limiter);
      await _engineRepo.setDither(on && _dspSettings.dither);
    } catch (e) {
      debugPrint('[DSP] 应用设置失败: $e');
    }
  }

  void loadDspPrefs() {
    _dspSettings = DspSettings(
      enabled: _prefsRepo.dspEnabled,
      crossfeed: _prefsRepo.dspCrossfeed,
      widener: _prefsRepo.dspWidener,
      limiter: _prefsRepo.dspLimiter,
      dither: _prefsRepo.dspDither,
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

  List<double> _eqValues = List.filled(10, 0.0);
  String _eqPreset = 'Flat';

  List<double> get eqValues => _eqValues;
  String get eqPreset => _eqPreset;

  /// 应用 EQ 预设：更新本地曲线并下发引擎。
  Future<void> applyEqPreset(String name) async {
    final gains = eqPresets[name];
    if (gains == null) return;
    _eqPreset = name;
    _eqValues = List.from(gains);
    notifyListeners();
    if (!_engineRepo.rustAvailable) return;
    try {
      await _engineRepo.applyPreset(_rustPresetNames[name] ?? name.toLowerCase());
    } catch (e) {
      debugPrint('[EQ] applyPreset 失败: $e');
    }
  }

  /// 手动调整单个频段增益：更新本地曲线并下发引擎，取消预设高亮。
  Future<void> setEqBand(int index, double gainDb) async {
    if (index < 0 || index >= _eqValues.length) return;
    _eqValues[index] = gainDb;
    _eqPreset = ''; // 手动调整后不再是纯预设
    notifyListeners();
    if (!_engineRepo.rustAvailable) return;
    try {
      await _engineRepo.setPeqBand(
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
