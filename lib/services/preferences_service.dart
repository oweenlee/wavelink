import 'package:shared_preferences/shared_preferences.dart';

/// 本地偏好持久化服务
/// 统一管理音量、循环模式、DSP 设置、ReplayGain、搜索历史等
class PreferencesService {
  PreferencesService._(this._prefs);

  final SharedPreferences _prefs;
  static PreferencesService? _instance;

  static Future<PreferencesService> init() async {
    final prefs = await SharedPreferences.getInstance();
    // 每次初始化都重建实例（测试可借助 setMockInitialValues 重置状态）
    _instance = PreferencesService._(prefs);
    return _instance!;
  }

  static PreferencesService get instance {
    assert(
      _instance != null,
      'PreferencesService 尚未初始化，请先调用 PreferencesService.init()',
    );
    return _instance!;
  }

  // ── 音量 ──
  static const _kVolume = 'volume';
  double get volume => _prefs.getDouble(_kVolume) ?? 0.8;
  Future<void> setVolume(double v) => _prefs.setDouble(_kVolume, v);

  // ── 循环模式 ──
  static const _kLoopMode = 'loop_mode';
  String get loopMode => _prefs.getString(_kLoopMode) ?? 'list';
  Future<void> setLoopMode(String mode) => _prefs.setString(_kLoopMode, mode);

  // ── 随机 ──
  static const _kShuffle = 'shuffle';
  bool get shuffle => _prefs.getBool(_kShuffle) ?? false;
  Future<void> setShuffle(bool v) => _prefs.setBool(_kShuffle, v);

  // ── DSP 设置 ──
  static const _kDspEnabled = 'dsp_enabled';
  static const _kCrossfeed = 'dsp_crossfeed';
  static const _kWidener = 'dsp_widener';
  static const _kLimiter = 'dsp_limiter';
  static const _kDither = 'dsp_dither';

  bool get dspEnabled => _prefs.getBool(_kDspEnabled) ?? false;
  bool get dspCrossfeed => _prefs.getBool(_kCrossfeed) ?? false;
  bool get dspWidener => _prefs.getBool(_kWidener) ?? false;
  bool get dspLimiter => _prefs.getBool(_kLimiter) ?? false;
  bool get dspDither => _prefs.getBool(_kDither) ?? false;

  Future<void> setDspEnabled(bool v) => _prefs.setBool(_kDspEnabled, v);
  Future<void> setDspCrossfeed(bool v) => _prefs.setBool(_kCrossfeed, v);
  Future<void> setDspWidener(bool v) => _prefs.setBool(_kWidener, v);
  Future<void> setDspLimiter(bool v) => _prefs.setBool(_kLimiter, v);
  Future<void> setDspDither(bool v) => _prefs.setBool(_kDither, v);

  // ── ReplayGain ──
  static const _kReplayGain = 'replay_gain';
  bool get replayGain => _prefs.getBool(_kReplayGain) ?? true;
  Future<void> setReplayGain(bool v) => _prefs.setBool(_kReplayGain, v);

  // ── 动态取色 ──
  static const _kDynamicColor = 'dynamic_color';
  bool get dynamicColor => _prefs.getBool(_kDynamicColor) ?? true;
  Future<void> setDynamicColor(bool v) => _prefs.setBool(_kDynamicColor, v);

  // ── 封面模糊强度 ──
  static const _kCoverBlur = 'cover_blur';
  double get coverBlur => _prefs.getDouble(_kCoverBlur) ?? 0.7;
  Future<void> setCoverBlur(double v) => _prefs.setDouble(_kCoverBlur, v);

  // ── 收藏 ──
  static const _kFavorites = 'favorites';
  Set<String> get favorites =>
      (_prefs.getStringList(_kFavorites) ?? []).toSet();
  Future<void> setFavorites(Set<String> ids) =>
      _prefs.setStringList(_kFavorites, ids.toList());

  // ── 搜索历史 ──
  static const _kSearchHistory = 'search_history';
  List<String> get searchHistory => _prefs.getStringList(_kSearchHistory) ?? [];
  Future<void> setSearchHistory(List<String> history) =>
      _prefs.setStringList(_kSearchHistory, history);

  Future<void> addSearchHistory(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return;
    final list = searchHistory;
    list.remove(trimmed);
    list.insert(0, trimmed);
    if (list.length > 20) list.removeRange(20, list.length);
    await setSearchHistory(list);
  }

  Future<void> removeSearchHistory(String term) async {
    final list = searchHistory;
    list.remove(term);
    await setSearchHistory(list);
  }

  Future<void> clearSearchHistory() => setSearchHistory([]);

  // ── 播放列表（id 列表，JSON 序列化）──
  static const _kPlaylists = 'playlists';

  /// 返回 {name: [songId,...]}
  Map<String, List<String>> get playlists {
    final raw = _prefs.getString(_kPlaylists);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = _decodeMap(raw);
      return decoded.map((k, v) => MapEntry(k, List<String>.from(v)));
    } catch (_) {
      return {};
    }
  }

  Future<void> setPlaylists(Map<String, List<String>> data) =>
      _prefs.setString(_kPlaylists, _encodeMap(data));

  Future<void> savePlaylist(String name, List<String> songIds) async {
    final data = playlists;
    data[name] = songIds;
    await setPlaylists(data);
  }
}

// 简单的扁平 Map 编解码，避免引入额外依赖
String _encodeMap(Map<String, List<String>> data) {
  final parts = data.entries
      .map((e) => '${Uri.encodeComponent(e.key)}:${e.value.join(',')}');
  return parts.join('|');
}

Map<String, List<String>> _decodeMap(String raw) {
  final result = <String, List<String>>{};
  for (final seg in raw.split('|')) {
    if (seg.isEmpty) continue;
    final idx = seg.indexOf(':');
    if (idx < 0) continue;
    final key = Uri.decodeComponent(seg.substring(0, idx));
    final vals = seg.substring(idx + 1);
    result[key] = vals.isEmpty ? [] : vals.split(',');
  }
  return result;
}
