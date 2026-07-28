import 'package:flutter/material.dart';
import '../models/playback_types.dart';
import '../services/rust_service.dart' as rs;
import '../services/preferences_service.dart';

class DspProvider extends ChangeNotifier {
  DspSettings _dspSettings = DspSettings();

  DspSettings get dspSettings => _dspSettings;
  bool get dspAvailable => true;

  Future<List<double>> getSpectrum() => rs.getSpectrum();
  Future<int> getUnderrunCount() => rs.getUnderrunCount();

  void toggleDspEnabled() {
    _dspSettings = _dspSettings.copyWith(enabled: !_dspSettings.enabled);
    PreferencesService.instance.setDspEnabled(_dspSettings.enabled);
    applyDsp();
    notifyListeners();
  }

  void toggleCrossfeed() {
    _dspSettings = _dspSettings.copyWith(crossfeed: !_dspSettings.crossfeed);
    PreferencesService.instance.setDspCrossfeed(_dspSettings.crossfeed);
    applyDsp();
    notifyListeners();
  }

  void toggleWidener() {
    _dspSettings = _dspSettings.copyWith(widener: !_dspSettings.widener);
    PreferencesService.instance.setDspWidener(_dspSettings.widener);
    applyDsp();
    notifyListeners();
  }

  void toggleLimiter() {
    _dspSettings = _dspSettings.copyWith(limiter: !_dspSettings.limiter);
    PreferencesService.instance.setDspLimiter(_dspSettings.limiter);
    notifyListeners();
  }

  void toggleDither() {
    _dspSettings = _dspSettings.copyWith(dither: !_dspSettings.dither);
    PreferencesService.instance.setDspDither(_dspSettings.dither);
    notifyListeners();
  }

  void applyEqPreset(EqPresetKind kind) {
    _dspSettings = _dspSettings.copyWith(preset: kind);
    applyDsp();
    notifyListeners();
  }

  String _presetName(EqPresetKind kind) => kind.name;

  Future<void> applyDsp() async {
    if (!rs.rustAvailable) return;
    try {
      if (_dspSettings.enabled) {
        await rs.engineApplyPreset(
            presetName: _presetName(_dspSettings.preset));
      } else {
        await rs.engineApplyPreset(presetName: 'flat');
      }
      await rs.engineSetCrossfeed(enabled: _dspSettings.crossfeed);
      await rs.engineSetStereoWidener(enabled: _dspSettings.widener, width: 0.5);
    } catch (e) {
      debugPrint('[DSP] 应用设置失败: $e');
    }
  }

  void loadDspPrefs() {
    final prefs = PreferencesService.instance;
    _dspSettings = DspSettings(
      enabled: prefs.dspEnabled,
      crossfeed: prefs.dspCrossfeed,
      widener: prefs.dspWidener,
      limiter: prefs.dspLimiter,
      dither: prefs.dspDither,
    );
  }
}
