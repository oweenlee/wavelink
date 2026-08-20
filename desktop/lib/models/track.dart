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

  // —— STRM 指针文件扩展（兼容 Kodi/Jellyfin 的 .strm 桩文件）——
  /// strm 文件在源内的路径（其所在源决定解析通道：NAS=SMB / WebDAV=DAV）。
  /// 非空即表示本曲是 .strm 指针，真实目标在 [targetUri]/[targetKind]。
  final String? strmPath;

  /// strm 文件所在源是否为 WebDAV（false = SMB/NAS）。仅 [isStrm] 时有意义。
  final bool strmFromWebdav;

  /// 解析出的真实目标地址：源内相对路径或完整 URL。
  final String? targetUri;

  /// 解析出的真实目标类型：smb / dav / http / stream。
  final String? targetKind;

  // —— CUE 分轨扩展（整轨镜像拆分的虚拟曲目）——
  /// 来源 .cue 文件路径（非空即本曲是 CUE 虚拟分轨）。
  final String? cuePath;

  /// 分轨在 CUE 展平列表中的 0-based 下标（播放时经
  /// `playQueueAt([cuePath], cueTrackIndex)` 定位起播）。
  final int? cueTrackIndex;

  /// CUE 展平后的总分轨数（播放后用于清空引擎侧剩余分轨，
  /// 队列控制权交还 Dart）。
  final int? cueTrackCount;

  /// 内嵌歌词（扫描期从标签读取：ID3 USLT / Vorbis LYRICS / MP4 ©lyr）。
  /// 外部同名 .lrc（[lyricsPath]）优先，内嵌作兜底。
  final String? lyricsText;

  /// 标签音轨号（专辑内排序：曲库按 艺人→专辑→音轨号 排序用）。
  final int? trackNumber;

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
    this.strmPath,
    this.strmFromWebdav = false,
    this.targetUri,
    this.targetKind,
    this.cuePath,
    this.cueTrackIndex,
    this.cueTrackCount,
    this.lyricsText,
    this.trackNumber,
  });

  bool get isLocal => source == TrackSource.local;
  bool get isNetwork => source != TrackSource.local;

  /// 是否为 CUE 虚拟分轨（播放走 playQueueAt + 清空引擎残余队列）。
  bool get isCueTrack => cuePath != null && cueTrackIndex != null;

  /// 是否为 .strm 指针文件（播放前需先解析出真实目标再分发）。
  bool get isStrm => strmPath != null && strmPath!.isNotEmpty;

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

  /// SQLite 持久化映射：Duration 存毫秒、bool 存 0/1、enum 存 name。
  /// 与 [TrackRepository] 的 tracks 表列一一对应。
  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'filePath': filePath,
        'lyricsPath': lyricsPath,
        'fallbackDurationMs': fallbackDuration.inMilliseconds,
        'source': source.name,
        'remotePath': remotePath,
        'streamUrl': streamUrl,
        'coverUrl': coverUrl,
        'durationHintMs': durationHint?.inMilliseconds,
        'durationEstimated': durationEstimated ? 1 : 0,
        'fileSize': fileSize,
        'strmPath': strmPath,
        'strmFromWebdav': strmFromWebdav ? 1 : 0,
        'targetUri': targetUri,
        'targetKind': targetKind,
        'cuePath': cuePath,
        'cueTrackIndex': cueTrackIndex,
        'cueTrackCount': cueTrackCount,
        'lyricsText': lyricsText,
        'trackNumber': trackNumber,
      };

  /// 从 SQLite 行构造 [Track]，缺省值兜底保持与模型默认值一致。
  factory Track.fromMap(Map<String, Object?> m) => Track(
        id: m['id'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        album: m['album'] as String?,
        filePath: m['filePath'] as String?,
        lyricsPath: m['lyricsPath'] as String?,
        fallbackDuration:
            Duration(milliseconds: (m['fallbackDurationMs'] as int?) ?? 210000),
        source: TrackSource.values.firstWhere(
          (e) => e.name == (m['source'] as String? ?? 'local'),
          orElse: () => TrackSource.local,
        ),
        remotePath: m['remotePath'] as String?,
        streamUrl: m['streamUrl'] as String?,
        coverUrl: m['coverUrl'] as String?,
        durationHint: m['durationHintMs'] == null
            ? null
            : Duration(milliseconds: m['durationHintMs'] as int),
        durationEstimated: (m['durationEstimated'] as int? ?? 0) == 1,
        fileSize: m['fileSize'] as int?,
        strmPath: m['strmPath'] as String?,
        strmFromWebdav: (m['strmFromWebdav'] as int? ?? 0) == 1,
        targetUri: m['targetUri'] as String?,
        targetKind: m['targetKind'] as String?,
        cuePath: m['cuePath'] as String?,
        cueTrackIndex: m['cueTrackIndex'] as int?,
        cueTrackCount: m['cueTrackCount'] as int?,
        lyricsText: m['lyricsText'] as String?,
        trackNumber: m['trackNumber'] as int?,
      );

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
    String? strmPath,
    bool? strmFromWebdav,
    String? targetUri,
    String? targetKind,
    String? cuePath,
    int? cueTrackIndex,
    int? cueTrackCount,
    String? lyricsText,
    int? trackNumber,
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
        strmPath: strmPath ?? this.strmPath,
        strmFromWebdav: strmFromWebdav ?? this.strmFromWebdav,
        targetUri: targetUri ?? this.targetUri,
        targetKind: targetKind ?? this.targetKind,
        cuePath: cuePath ?? this.cuePath,
        cueTrackIndex: cueTrackIndex ?? this.cueTrackIndex,
        cueTrackCount: cueTrackCount ?? this.cueTrackCount,
        lyricsText: lyricsText ?? this.lyricsText,
        trackNumber: trackNumber ?? this.trackNumber,
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
