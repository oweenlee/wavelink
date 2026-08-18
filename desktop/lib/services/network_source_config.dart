import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';

/// 网络音源配置（WebDAV / NAS(SMB) / Subsonic）的本地持久化中心。
///
/// 单例，持有 [SharedPreferences] 实例，统一管理三类来源的
/// 连接凭据、曲库展示开关，并在配置变化时广播 [onChange]，供 Riverpod
/// 侧 [StreamProvider] 感知并刷新侧栏音源区。
///
/// 设计对齐 mobile 的 [PreferencesService] 网络部分，但桌面端合并为单一
/// 服务（避免移动端拆分过细带来的样板）。
class NetworkSourceConfig {
  NetworkSourceConfig._(this._prefs);

  final SharedPreferences _prefs;
  static NetworkSourceConfig? _instance;

  /// 启动时调用一次，加载 SharedPreferences 并建立单例。
  static Future<NetworkSourceConfig> init() async {
    final prefs = await SharedPreferences.getInstance();
    _instance = NetworkSourceConfig._(prefs);
    return _instance!;
  }

  static NetworkSourceConfig get instance {
    assert(
      _instance != null,
      'NetworkSourceConfig 尚未初始化，请先调用 NetworkSourceConfig.init()',
    );
    return _instance!;
  }

  /// 配置变化广播（保存凭据 / 切换展示开关时触发）。
  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChange => _changed.stream;
  void _notify() => _changed.add(null);

  // ── 曲库展示开关（按来源过滤） ──
  bool _show(String key) => _prefs.getBool(key) ?? true;
  Future<void> _setShow(String key, bool v) async {
    await _prefs.setBool(key, v);
    _notify();
  }

  bool showSource(TrackSource s) => switch (s) {
        TrackSource.local => _show(_kShowLocal),
        TrackSource.webdav => _show(_kShowWebdav),
        TrackSource.nas => _show(_kShowNas),
        TrackSource.subsonic => _show(_kShowSubsonic),
      };

  Future<void> setShowSource(TrackSource s, bool v) => switch (s) {
        TrackSource.local => _setShow(_kShowLocal, v),
        TrackSource.webdav => _setShow(_kShowWebdav, v),
        TrackSource.nas => _setShow(_kShowNas, v),
        TrackSource.subsonic => _setShow(_kShowSubsonic, v),
      };

  // ── WebDAV ──
  String? get webdavBaseUrl => _prefs.getString(_kWebdavBaseUrl);
  String? get webdavPath => _prefs.getString(_kWebdavPath);
  String? get webdavUsername => _prefs.getString(_kWebdavUsername);
  String get webdavPassword => _prefs.getString(_kWebdavPassword) ?? '';

  Future<void> setWebdavConfig({
    required String baseUrl,
    required String path,
    required String username,
    required String password,
  }) async {
    await _prefs.setString(_kWebdavBaseUrl, baseUrl.trim());
    await _prefs.setString(_kWebdavPath, path.trim());
    await _prefs.setString(_kWebdavUsername, username.trim());
    await _prefs.setString(_kWebdavPassword, password);
    _notify();
  }

  Future<void> clearWebdavConfig() async {
    await _prefs.remove(_kWebdavBaseUrl);
    await _prefs.remove(_kWebdavPath);
    await _prefs.remove(_kWebdavUsername);
    await _prefs.remove(_kWebdavPassword);
    _notify();
  }

  // ── Subsonic / Navidrome / Jellyfin ──
  String? get subsonicBaseUrl => _prefs.getString(_kSubsonicBaseUrl);
  String? get subsonicUsername => _prefs.getString(_kSubsonicUsername);
  String get subsonicPassword => _prefs.getString(_kSubsonicPassword) ?? '';

  Future<void> setSubsonicConfig({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    await _prefs.setString(_kSubsonicBaseUrl, baseUrl.trim());
    await _prefs.setString(_kSubsonicUsername, username.trim());
    await _prefs.setString(_kSubsonicPassword, password);
    _notify();
  }

  Future<void> clearSubsonicConfig() async {
    await _prefs.remove(_kSubsonicBaseUrl);
    await _prefs.remove(_kSubsonicUsername);
    await _prefs.remove(_kSubsonicPassword);
    _notify();
  }

  // ── NAS (SMB) ──
  String? get nasHost => _prefs.getString(_kNasHost);
  int get nasPort => _prefs.getInt(_kNasPort) ?? 445;
  String? get nasShare => _prefs.getString(_kNasShare);
  String? get nasUsername => _prefs.getString(_kNasUsername);
  String get nasPassword => _prefs.getString(_kNasPassword) ?? '';
  String get nasDomain => _prefs.getString(_kNasDomain) ?? '';

  Future<void> setNasConfig({
    required String host,
    required int port,
    required String share,
    required String username,
    required String password,
    String domain = '',
  }) async {
    await _prefs.setString(_kNasHost, host.trim());
    await _prefs.setInt(_kNasPort, port);
    await _prefs.setString(_kNasShare, share.trim());
    await _prefs.setString(_kNasUsername, username.trim());
    await _prefs.setString(_kNasPassword, password);
    await _prefs.setString(_kNasDomain, domain.trim());
    _notify();
  }

  Future<void> clearNasConfig() async {
    await _prefs.remove(_kNasHost);
    await _prefs.remove(_kNasPort);
    await _prefs.remove(_kNasShare);
    await _prefs.remove(_kNasUsername);
    await _prefs.remove(_kNasPassword);
    await _prefs.remove(_kNasDomain);
    _notify();
  }

  // ── prefs keys ──
  static const _kShowLocal = 'show_source_local';
  static const _kShowWebdav = 'show_source_webdav';
  static const _kShowNas = 'show_source_nas';
  static const _kShowSubsonic = 'show_source_subsonic';

  static const _kWebdavBaseUrl = 'webdav_base_url';
  static const _kWebdavPath = 'webdav_path';
  static const _kWebdavUsername = 'webdav_username';
  static const _kWebdavPassword = 'webdav_password';

  static const _kSubsonicBaseUrl = 'subsonic_base_url';
  static const _kSubsonicUsername = 'subsonic_username';
  static const _kSubsonicPassword = 'subsonic_password';

  static const _kNasHost = 'nas_host';
  static const _kNasPort = 'nas_port';
  static const _kNasShare = 'nas_share';
  static const _kNasUsername = 'nas_username';
  static const _kNasPassword = 'nas_password';
  static const _kNasDomain = 'nas_domain';
}
