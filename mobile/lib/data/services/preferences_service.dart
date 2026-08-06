import 'package:flutter/foundation.dart';
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

  // ── Bit-perfect / 采样率跟随 ──
  static const _kBitPerfect = 'bit_perfect';
  bool get bitPerfect => _prefs.getBool(_kBitPerfect) ?? false;
  Future<void> setBitPerfect(bool v) => _prefs.setBool(_kBitPerfect, v);

  // ── 断点续播（会话恢复）──
  // 保存上次播放的队列（歌曲 id 列表）、当前索引与播放位置（ms）。
  // 启动后曲库就绪时恢复队列与位置，不自动播放，用户点播放继续。
  static const _kResumeQueue = 'resume_queue';
  static const _kResumeIndex = 'resume_index';
  static const _kResumePositionMs = 'resume_position_ms';

  List<String> get resumeQueue => _prefs.getStringList(_kResumeQueue) ?? [];
  int get resumeIndex => _prefs.getInt(_kResumeIndex) ?? 0;
  double get resumePositionMs => _prefs.getDouble(_kResumePositionMs) ?? 0;

  Future<void> setResume({
    required List<String> queueIds,
    required int index,
    required double positionMs,
  }) async {
    await _prefs.setStringList(_kResumeQueue, queueIds);
    await _prefs.setInt(_kResumeIndex, index);
    await _prefs.setDouble(_kResumePositionMs, positionMs);
  }

  Future<void> clearResume() async {
    await _prefs.remove(_kResumeQueue);
    await _prefs.remove(_kResumeIndex);
    await _prefs.remove(_kResumePositionMs);
  }

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

  // ── 播放列表（id 列表，JSON 序列化）──
  static const _kPlaylists = 'playlists';

  /// 返回 {name: [songId,...]}
  Map<String, List<String>> get playlists {
    final raw = _prefs.getString(_kPlaylists);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = _decodeMap(raw);
      return decoded.map((k, v) => MapEntry(k, List<String>.from(v)));
    } catch (e) {
      debugPrint('[Prefs] 播放列表解码失败: $e');
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

  // ── 频谱可视化 ──

  // ── NAS 配置 ──

  static const _kNasType = 'nas_type';
  static const _kNasHost = 'nas_host';
  static const _kNasShare = 'nas_share';
  static const _kNasUsername = 'nas_username';
  static const _kNasPassword = 'nas_password';
  static const _kNasEnabled = 'nas_enabled';

  /// SMB 离线缓存：开启后扫描 NAS 时把整库下载到本机，关 SMB 也能播。
  /// 默认关闭——只建索引，播放时才按需下载单曲。
  static const _kSmbOfflineCache = 'smb_offline_cache';
  bool get smbOfflineCache => _prefs.getBool(_kSmbOfflineCache) ?? false;
  Future<void> setSmbOfflineCache(bool v) =>
      _prefs.setBool(_kSmbOfflineCache, v);

  String? get nasType => _prefs.getString(_kNasType);
  String? get nasHost => _prefs.getString(_kNasHost);
  String? get nasShare => _prefs.getString(_kNasShare);
  String? get nasUsername => _prefs.getString(_kNasUsername);
  String get nasPassword => _prefs.getString(_kNasPassword) ?? '';
  bool get nasEnabled => _prefs.getBool(_kNasEnabled) ?? false;

  Future<void> setNasConfig({
    String? type,
    String? host,
    String? share,
    String? username,
    String? password,
    bool? enabled,
  }) async {
    if (type != null) await _prefs.setString(_kNasType, type);
    if (host != null) await _prefs.setString(_kNasHost, host);
    if (share != null) await _prefs.setString(_kNasShare, share);
    if (username != null) await _prefs.setString(_kNasUsername, username);
    if (password != null) await _prefs.setString(_kNasPassword, password);
    if (enabled != null) await _prefs.setBool(_kNasEnabled, enabled);
  }

  Future<void> clearNasConfig() async {
    await _prefs.remove(_kNasType);
    await _prefs.remove(_kNasHost);
    await _prefs.remove(_kNasShare);
    await _prefs.remove(_kNasUsername);
    await _prefs.remove(_kNasPassword);
    await _prefs.remove(_kNasEnabled);
  }

  // ── 语言偏好 ──
  // 取值：'system' | 'zh' | 'en'；'system' 表示跟随系统
  static const _kLocale = 'locale';
  String get localePref => _prefs.getString(_kLocale) ?? 'system';
  Future<void> setLocalePref(String v) => _prefs.setString(_kLocale, v);
}

// 简单的扁平 Map 编解码，避免引入额外依赖
String _encodeMap(Map<String, List<String>> data) {
  final parts = data.entries.map(
    (e) =>
        '${Uri.encodeComponent(e.key)}:${e.value.map(Uri.encodeComponent).join(',')}',
  );
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
    result[key] = vals.isEmpty
        ? []
        : vals.split(',').map(Uri.decodeComponent).toList();
  }
  return result;
}
