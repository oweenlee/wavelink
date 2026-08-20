/// NAS（SMB）连接配置档案。
///
/// 一套「地址 + 端口 + 共享路径 + 凭据」的完整连接配置。同一服务器同一
/// 共享路径（[id] 指纹一致）视为同一配置，重复保存仅更新凭据等字段。
/// 曲库中 NAS 歌曲属于当前「激活」的配置（见 PreferencesService 的
/// nasHost/nasShare 等激活字段），切换激活配置即切换曲库数据源。
class NasProfile {
  final String host;
  final int port;
  final String share;
  final String username;
  final String password;
  final String? type;
  final DateTime savedAt;

  const NasProfile({
    required this.host,
    this.port = 445,
    this.share = '',
    this.username = '',
    this.password = '',
    this.type,
    required this.savedAt,
  });

  /// 稳定指纹：同一服务器同一共享路径视为同一配置（不含凭据）。
  String get id => '${host.toLowerCase()}:$port:${share.trim()}';

  /// 展示名：host 加共享路径（如 `192.168.1.5 · Music`）
  String get displayName {
    final h = host.trim();
    final s = share.trim();
    if (s.isEmpty) return h;
    final shareName = s.split('/').first;
    return '$h · $shareName';
  }

  /// 判断是否与另一配置指向同一连接目标（忽略凭据）
  bool sameTarget(NasProfile other) => id == other.id;

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'share': share,
    'username': username,
    'password': password,
    'type': type,
    'savedAt': savedAt.toIso8601String(),
  };

  factory NasProfile.fromJson(Map<String, Object?> json) => NasProfile(
    host: json['host'] as String? ?? '',
    port: json['port'] as int? ?? 445,
    share: json['share'] as String? ?? '',
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    type: json['type'] as String?,
    savedAt:
        DateTime.tryParse(json['savedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}