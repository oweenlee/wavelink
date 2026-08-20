import '../services/preferences_service.dart';

/// 用户偏好设置的单一来源
///
/// 封装 SharedPreferences 的所有读写操作
/// 当前直接委托给 PreferencesService，后续可替换存储后端
class PreferencesRepository {
  // ── 音量 ──

  double get volume => PreferencesService.instance.volume;
  Future<void> setVolume(double v) => PreferencesService.instance.setVolume(v);

  // ── 循环模式 ──

  String get loopMode => PreferencesService.instance.loopMode;
  Future<void> setLoopMode(String mode) =>
      PreferencesService.instance.setLoopMode(mode);

  // ── 随机 ──

  bool get shuffle => PreferencesService.instance.shuffle;
  Future<void> setShuffle(bool v) => PreferencesService.instance.setShuffle(v);

  // ── DSP 设置 ──

  bool get dspEnabled => PreferencesService.instance.dspEnabled;
  bool get dspCrossfeed => PreferencesService.instance.dspCrossfeed;
  bool get dspWidener => PreferencesService.instance.dspWidener;
  bool get dspLimiter => PreferencesService.instance.dspLimiter;

  Future<void> setDspEnabled(bool v) =>
      PreferencesService.instance.setDspEnabled(v);
  Future<void> setDspCrossfeed(bool v) =>
      PreferencesService.instance.setDspCrossfeed(v);
  Future<void> setDspWidener(bool v) =>
      PreferencesService.instance.setDspWidener(v);
  Future<void> setDspLimiter(bool v) =>
      PreferencesService.instance.setDspLimiter(v);

  // ── AutoEQ / 参量 EQ ──

  String? get autoEqModel => PreferencesService.instance.autoEqModel;
  Future<void> setAutoEqModel(String? model) =>
      PreferencesService.instance.setAutoEqModel(model);

  String? get roomIrPath => PreferencesService.instance.roomIrPath;
  Future<void> setRoomIrPath(String? path) =>
      PreferencesService.instance.setRoomIrPath(path);

  String get eqPreset => PreferencesService.instance.eqPreset;
  List<double> get eqGains => PreferencesService.instance.eqGains;
  Future<void> setEqState({
    required String preset,
    required List<double> gains,
  }) => PreferencesService.instance.setEqState(preset: preset, gains: gains);

  // ── 播放列表 ──

  Map<String, List<String>> get playlists =>
      PreferencesService.instance.playlists;
  Future<void> savePlaylist(String name, List<String> songIds) =>
      PreferencesService.instance.savePlaylist(name, songIds);
  Future<void> setPlaylists(Map<String, List<String>> data) =>
      PreferencesService.instance.setPlaylists(data);

  // ── 外观偏好 ──

  bool get replayGain => PreferencesService.instance.replayGain;
  Future<void> setReplayGain(bool v) =>
      PreferencesService.instance.setReplayGain(v);

  bool get bitPerfect => PreferencesService.instance.bitPerfect;
  Future<void> setBitPerfect(bool v) =>
      PreferencesService.instance.setBitPerfect(v);

  double get coverBlur => PreferencesService.instance.coverBlur;
  Future<void> setCoverBlur(double v) =>
      PreferencesService.instance.setCoverBlur(v);

  // ── 断点续播 ──

  List<String> get resumeQueue => PreferencesService.instance.resumeQueue;
  int get resumeIndex => PreferencesService.instance.resumeIndex;
  double get resumePositionMs => PreferencesService.instance.resumePositionMs;
  Future<void> setResume({
    required List<String> queueIds,
    required int index,
    required double positionMs,
  }) => PreferencesService.instance.setResume(
    queueIds: queueIds,
    index: index,
    positionMs: positionMs,
  );

  Future<void> clearResume() => PreferencesService.instance.clearResume();

  // ── NAS 配置 ──

  String? get nasType => PreferencesService.instance.nasType;
  String? get nasHost => PreferencesService.instance.nasHost;
  String? get nasShare => PreferencesService.instance.nasShare;
  String? get nasUsername => PreferencesService.instance.nasUsername;
  String get nasPassword => PreferencesService.instance.nasPassword;

  Future<void> setNasConfig({
    String? type,
    String? host,
    String? share,
    String? username,
    String? password,
  }) => PreferencesService.instance.setNasConfig(
    type: type,
    host: host,
    share: share,
    username: username,
    password: password,
  );

  Future<void> clearNasConfig() => PreferencesService.instance.clearNasConfig();
}
