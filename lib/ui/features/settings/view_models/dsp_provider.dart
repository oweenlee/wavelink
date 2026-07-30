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
    notifyListeners();
  }

  void toggleDither() {
    _dspSettings = _dspSettings.copyWith(dither: !_dspSettings.dither);
    _prefsRepo.setDspDither(_dspSettings.dither);
    notifyListeners();
  }

  Future<void> applyDsp() async {
    if (!_engineRepo.rustAvailable) return;
    try {
      await _engineRepo.setCrossfeed(_dspSettings.crossfeed);
      await _engineRepo.setStereoWidener(_dspSettings.widener, 0.5);
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
}
