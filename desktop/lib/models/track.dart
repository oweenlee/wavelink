/// 曲目来源。与 mobile 的 [SongSource] 对齐（mobile 另有 appleMusic/imported，
/// 桌面端当前聚焦四类真实可播放来源）。
///
/// - local:    本机文件系统（[filePath] 指向本地文件，直接播放）
/// - webdav:   WebDAV 服务器（[remotePath] 为服务器内相对路径，经 Rust 边下边播）
/// - nas:      SMB / NAS 共享（[remotePath] 为共享内相对路径，经 Rust 边下边播）
/// - subsonic: Subsonic / Navidrome / Jellyfin 音乐服务器
///             （[streamUrl] 为完整流地址，先下载缓存再本地播放）
enum TrackSource { local, webdav, nas, subsonic }

/// 单曲模型。桌面端在 mobile `Song` 基础上收敛出 PC 场景需要的字段：
/// 本地曲目保留 [filePath]；网络曲目用 [source] + [remotePath]/[streamUrl]
/// 描述来源，[durationHint] 记录扫描期已知的真实时长。
class Track {
  final String id;
  final String title;
  final String artist;
  final String? album; // 专辑名（网络扫描期可能为占位值）
  final String? filePath; // null 表示非本地文件（网络来源）
  final String? lyricsPath; // 同级 .lrc（本地曲目优先）
  final Duration fallbackDuration; // 无音频源时的占位时长（simulated 模式）

  // —— 网络音源扩展 ——
  final TrackSource source;

  /// 远端路径：webdav 为 davPath（服务器内相对路径），nas 为 smb 相对路径，
  /// subsonic 为服务器返回的 song id（仅用于去重/调试展示）。
  final String? remotePath;

  /// subsonic 完整流地址（含凭据 query），其余来源为 null。
  final String? streamUrl;

  /// 远程封面地址（subsonic 直接提供 URL；webdav/nas 后续扩展）。
  final String? coverUrl;

  /// 扫描期已知的真实时长（subsonic/nas 提供）；null 表示未知/估算。
  final Duration? durationHint;

  /// 时长是否为估算值（按文件大小推算），用于 UI 提示。
  final bool durationEstimated;

  /// 远端文件真实字节数（扫描期已知）。用于：① 播放时作为流的总长度
  /// （content_length）传给引擎，让 symphonia 算出真实时长，进度条准确；
  /// ② 缓存命中判断（大小变化视为文件更新）。本地曲目为 null。
  final int? fileSize;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.filePath,
    this.lyricsPath,
    this.fallbackDuration = const Duration(seconds: 210),
    this.source = TrackSource.local,
    this.remotePath,
    this.streamUrl,
    this.coverUrl,
    this.durationHint,
    this.durationEstimated = false,
    this.fileSize,
  });

  bool get isLocal => source == TrackSource.local;
  bool get isNetwork => source != TrackSource.local;

  /// 是否有可播放的音频源（按来源分别判定）。
  bool get hasSource => switch (source) {
        TrackSource.local => filePath != null,
        TrackSource.webdav => remotePath != null,
        TrackSource.nas => remotePath != null,
        TrackSource.subsonic => streamUrl != null,
      };

  /// 用于 UI 角标的简短来源标签。
  String get sourceLabel => switch (source) {
        TrackSource.local => '本地',
        TrackSource.webdav => 'WebDAV',
        TrackSource.nas => 'NAS',
        TrackSource.subsonic => 'Subsonic',
      };

  Track copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? filePath,
    String? lyricsPath,
    Duration? fallbackDuration,
    TrackSource? source,
    String? remotePath,
    String? streamUrl,
    String? coverUrl,
    Duration? durationHint,
    bool? durationEstimated,
    int? fileSize,
  }) =>
      Track(
        id: id ?? this.id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        filePath: filePath ?? this.filePath,
        lyricsPath: lyricsPath ?? this.lyricsPath,
        fallbackDuration: fallbackDuration ?? this.fallbackDuration,
        source: source ?? this.source,
        remotePath: remotePath ?? this.remotePath,
        streamUrl: streamUrl ?? this.streamUrl,
        coverUrl: coverUrl ?? this.coverUrl,
        durationHint: durationHint ?? this.durationHint,
        durationEstimated: durationEstimated ?? this.durationEstimated,
        fileSize: fileSize ?? this.fileSize,
      );

  @override
  String toString() => '$artist - $title';
}

/// [TrackSource] 简短角标（用于曲目行的小标签）。
extension TrackSourceX on TrackSource {
  String get short => switch (this) {
        TrackSource.local => '本地',
        TrackSource.webdav => 'DAV',
        TrackSource.nas => 'NAS',
        TrackSource.subsonic => 'SUB',
      };
}
