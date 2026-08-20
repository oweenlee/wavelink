import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as wd;
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';
import 'log.dart';
import 'lrc_codec.dart';
import 'preferences_service.dart';
import 'rust_service.dart' as rs;
import 'strm_resolver.dart';
import '../../src/rust/api/metadata.dart' show MetadataResult;

/// WebDAV 音乐服务器服务
///
/// 基于 [wd.Client]（digest/basic/无认证自动协商）访问远程 WebDAV 目录，
/// 扫描、下载音频并缓存到本地。播放策略为「全量下载再播」：
/// 与 SMB 的边下边播不同，WebDAV 先整曲下载到 `.webdav_cache/` 再播放
/// （HTTP 层后续可扩展 Range 分块升级为流式）。
///
/// 配置复用 [PreferencesService] 的 webdavBaseUrl/webdavPath/webdavUsername/
/// webdavPassword。服务器内路径相对 baseUrl（不含主机部分）。
class WebdavService {
  WebdavService._();

  /// 懒创建的 WebDAV client（按 baseUrl|user|pass 指纹缓存复用；
  /// digest 协商结果保存在 client 内，复用可避免每次重新握手）。
  static wd.Client? _client;
  static String? _clientKey;

  /// 扫描进行中标记：期间禁止重复扫描
  static bool _scanning = false;

  /// 进行中的下载（按 davPath 去重）：并发调用共享同一次下载，
  /// 避免两个任务写同一个 .part 文件互相截断。
  static final Map<String, Future<String?>> _downloading = {};

  /// 最近一次操作的具体错误信息（用于 UI 展示排查）
  static String? lastError;

  /// 扫描期元数据占位标记（未读元数据时统一用这些值占位）。
  static const albumPlaceholder = 'WebDAV Music';
  static const artistPlaceholder = 'Unknown Artist';

  static String? get baseUrl => PreferencesService.instance.webdavBaseUrl;
  static String? get rootPath => PreferencesService.instance.webdavPath;

  /// WebDAV 认证凭据（流式播放 Rust 侧需要）
  static String get username => PreferencesService.instance.webdavUsername ?? '';
  static String get password => PreferencesService.instance.webdavPassword;

  /// 是否有配置（baseUrl 非空即视为已配置）
  static bool get isConfigured {
    final base = baseUrl;
    return base != null && base.isNotEmpty;
  }

  /// 拼接远端完整 URL（baseUrl + davPath），规则同 webdav_client 的 join：
  /// 斜杠规范化；davPath 若已是完整 URL 则原样返回。
  static String? fullUrlFor(String davPath) {
    final base = baseUrl;
    if (base == null || base.isEmpty) return null;
    if (davPath.startsWith('http://') || davPath.startsWith('https://')) {
      return davPath;
    }
    final l = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final r = davPath.startsWith('/') ? davPath.substring(1) : davPath;
    return '$l/$r';
  }

  /// 返回 davPath 对应的本地缓存目标路径，并确保缓存目录存在。
  /// 命名规则与 cachedLocalPath 一致（下次播放直接命中）。
  static Future<String?> cacheTargetFor(String davPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.webdav_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = davPath.split('/').last;
      return '${cacheDir.path}/${davPath.hashCode}_$name';
    } catch (e) {
      Log.e('WebDAV', 'cacheTargetFor failed: $e');
      return null;
    }
  }

  /// 懒创建/复用 client。配置变更（指纹变化）时重建。
  static Future<wd.Client?> _ensureClient() async {
    final base = baseUrl;
    if (base == null || base.isEmpty) {
      lastError = 'WebDAV base URL not configured';
      return null;
    }
    final user = PreferencesService.instance.webdavUsername ?? '';
    final pass = PreferencesService.instance.webdavPassword;
    return _buildClient(base, user, pass);
  }

  static wd.Client? _buildClient(String base, String user, String pass) {
    final key = '$base|$user|$pass';
    if (_client == null || _clientKey != key) {
      _client = wd.newClient(base, user: user, password: pass);
      _client!.setConnectTimeout(10000);
      _client!.setReceiveTimeout(30000);
      _clientKey = key;
      Log.d(
        'WebDAV',
        '新建 client: ${Uri.tryParse(base)?.host ?? base}'
            '（${user.isEmpty ? '匿名' : '用户 $user'}）',
      );
    }
    return _client;
  }

  /// 连接测试：OPTIONS 探测 + 根目录可列即视为通过。
  /// 用显式参数（未保存的临时配置），返回 null 表示成功，否则错误信息。
  static Future<String?> testConnection({
    required String baseUrl,
    String path = '',
    String username = '',
    String password = '',
  }) async {
    // 连接前网络检测：无网络直接给明确提示（与 SMB 对齐），不甩底层异常
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.isEmpty || connectivity.contains(ConnectivityResult.none)) {
      lastError = '未连接网络：请先连上 Wi-Fi（如需访问局域网/公网服务器）';
      return lastError;
    }
    final sw = Stopwatch()..start();
    Log.i(
      'WebDAV',
      '连接测试开始: $baseUrl$path'
          '（${username.isEmpty ? '匿名' : '用户 $username'}）',
    );
    try {
      final client = wd.newClient(baseUrl, user: username, password: password);
      client.setConnectTimeout(10000);
      client.setReceiveTimeout(30000);
      await client.ping().timeout(const Duration(seconds: 15));
      final entries = await client
          .readDir(path)
          .timeout(const Duration(seconds: 15));
      Log.i(
        'WebDAV',
        '连接测试通过（${sw.elapsedMilliseconds}ms，'
            '根目录 ${entries.length} 个条目）',
      );
      return null;
    } catch (e) {
      lastError = _friendlyTestError(e);
      Log.e(
        'WebDAV',
        'testConnection failed (${sw.elapsedMilliseconds}ms): $lastError',
      );
      return lastError;
    }
  }

  /// 测试连接失败分类：把底层异常（SocketException/超时/HTTP 状态码）
  /// 映射成可操作的提示。网络不通、URL 指向错误、凭据错误是三类常见原因。
  static String _friendlyTestError(Object e) {
    final s = e.toString();
    final lower = s.toLowerCase();
    if (lower.contains('refused') ||
        lower.contains('no route to host') ||
        lower.contains('unreachable') ||
        lower.contains('failed host lookup')) {
      return '无法连接服务器（$s）\n请确认地址与端口正确、服务器已开启 WebDAV 服务，且设备已连上可访问该服务器的网络。';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return '连接超时（$s）\n请确认服务器已开机、WebDAV 服务已开启，并检查网络是否可达该服务器。';
    }
    if (lower.contains('401') || lower.contains('403')) {
      return '凭据被拒绝（HTTP 401/403）：请检查用户名与密码是否正确。';
    }
    if (lower.contains('404') || lower.contains('405')) {
      return '服务器响应异常（HTTP $s）\n请确认 URL 指向的是 WebDAV 根路径（通常为 /dav/ 或 /remote.php/dav/）。';
    }
    return '连接失败（$s）\n请检查 URL、端口、用户名密码是否正确。';
  }

  /// 递归扫描音频文件，按 [onBatch] 增量回调（缓冲 20 首）。
  /// 返回**全量**结果（与 SMB 一致）：[buffer] 负责批次刷新，[songs]
  /// 只累积不清空——调用方的 prune 依赖全量列表做差集。
  /// 扫描失败抛异常（由调用方捕获/回显），与「服务器真空库返回空」可区分。
  static Future<List<Song>> scanWebdav({
    void Function(List<Song> batch)? onBatch,
  }) async {
    if (_scanning) return [];
    _scanning = true;
    lastError = null;
    final sw = Stopwatch()..start();
    final root = rootPath ?? '';
    Log.i(
      'WebDAV',
      '扫描开始: ${Uri.tryParse(baseUrl ?? '')?.host ?? '?'}'
          ' 根目录 ${root.isEmpty ? '/' : root}',
    );
    final songs = <Song>[];
    final buffer = <Song>[];
    var dirs = 0, batches = 0;
    void flush() {
      if (buffer.isNotEmpty) {
        onBatch?.call(List<Song>.from(buffer));
        batches++;
        buffer.clear();
      }
    }

    try {
      final client = await _ensureClient();
      if (client == null) return [];
      await _scanDir(client, root, songs, buffer, flush, (d) => dirs += d);
    } finally {
      _scanning = false;
    }
    flush();
    Log.i(
      'WebDAV',
      '扫描完成: ${songs.length} 首歌 / $dirs 个目录 / '
          '$batches 批（${sw.elapsedMilliseconds}ms）',
    );
    return songs;
  }

  static Future<void> _scanDir(
    wd.Client client,
    String path,
    List<Song> songs,
    List<Song> buffer,
    void Function() flush,
    void Function(int) countDir,
  ) async {
    List<wd.File> entries;
    try {
      entries = await client.readDir(path).timeout(const Duration(seconds: 30));
    } catch (e) {
      // 单目录失败隔离（超时/403 等）：跳过该目录继续扫其余，
      // 避免一个坏目录导致整次扫描失败。与 SMB 吞单文件失败语义对齐。
      Log.w('WebDAV', 'readDir 失败，跳过该目录 ($path): $e');
      return;
    }
    countDir(1);
    for (final entry in entries) {
      // 畸形响应防护：条目缺 path 直接跳过（避免空断言崩溃）
      final entryPath = entry.path;
      if (entryPath == null || entryPath.isEmpty) continue;
      if (entry.isDir == true) {
        // 递归子目录（单层 readDir + 递归，不依赖服务器 DEPTH infinity）
        await _scanDir(client, entryPath, songs, buffer, flush, countDir);
      } else {
        final song = await _toSong(entry);
        if (song != null) {
          songs.add(song);
          buffer.add(song);
          if (buffer.length >= 20) flush();
        }
      }
    }
  }

  /// 单个远程文件 → Song 索引（只建索引，不下载、不读元数据）。
  /// 服务端 size 缺失时按 0 处理（时长估算为 0，不阻断扫描）。
  /// STRM 文件在此阶段 Resolver 落地：读内容解析目标（失败不阻断索引）。
  static Future<Song?> _toSong(wd.File entry) async {
    final name = entry.name ?? '';
    final path = entry.path ?? '';
    if (name.isEmpty || path.isEmpty) return null;
    final ext = name.split('.').last.toLowerCase();
    if (!ImportService.extensions.contains(ext)) {
      // STRM 指针文件：按歌建索引（标题取 strm 文件名），播放时读
      // 内容解析真实目标再走对应源（strm 是文本，无音频标签可读）。
      if (ext != 'strm') return null;
      final parsed = ImportService.parseArtistTitle(
        name.replaceAll(RegExp(r'\.[^.]+$'), ''),
      );
      StrmTarget? target;
      try {
        final text = await readRemoteText(path);
        if (text != null) {
          target =
              parseStrmContent(text, fromWebdav: true, strmPath: path);
        }
      } catch (e) {
        Log.w('WebDAV', 'STRM 解析失败 ($path): $e');
      }
      final song = Song(
        id: 'dav_${path.hashCode}',
        title: parsed.title,
        artist: artistPlaceholder,
        album: albumPlaceholder,
        duration: Duration.zero,
        dominantColor: AppTheme.s2,
        strmPath: path,
        strmFromWebdav: true,
        targetUri: target?.path,
        targetKind: target?.kind,
        durationEstimated: true,
      );
      // #EXTINF 标题/时长回填（Kodi 风格 strm 库的展示名）
      if (target != null) applyExtInfToSong(song, target);
      return song;
    }
    final parsed = ImportService.parseArtistTitle(name);
    return Song(
      id: 'dav_${path.hashCode}',
      title: parsed.title,
      artist: artistPlaceholder,
      album: albumPlaceholder,
      duration: ImportService.estimateDuration(entry.size ?? 0, name),
      dominantColor: AppTheme.s2,
      davPath: path,
      durationEstimated: true,
    );
  }

  /// 元数据是否仍为扫描期占位值：扫描只按文件名建索引，album/artist/
  /// 时长统一占位；封面提取读头解析时一并回填真实值（与 SMB 对齐）。
  static bool needsMetadata(Song song) =>
      song.album == albumPlaceholder ||
      song.artist == artistPlaceholder ||
      song.durationEstimated;

  /// 读取远端文件头/尾字节（Range 请求，只拉 [maxLen] 前部或后部，服务器
  /// 忽略 Range 时 Rust 侧也主动截断，不下载整曲）。[suffix] 为 true 时
  /// 读文件尾（Range: bytes=-N，非 faststart 的 M4A moov 在尾部）。
  static Future<List<int>> readRemoteBytes(
    String url,
    int maxLen, {
    bool suffix = false,
  }) async {
    try {
      final bytes = await rs.readWebdavRange(
        url: url,
        username: username,
        password: password,
        maxLen: maxLen,
        suffix: suffix,
      );
      return bytes;
    } catch (e) {
      Log.w('WebDAV', 'readRemoteBytes failed ($url): $e');
      return const [];
    }
  }

  /// 远端封面提取：Range 读头 1MB → 写带真实扩展名的临时文件 → lofty
  /// 解析内嵌封面 → 写 .covers 缓存。头读不到元数据（非 faststart 的
  /// M4A/ALAC，moov 在文件尾）时再读尾 1MB 拼接成近似完整文件二次解析。
  /// 返回是否有进展（拿到封面或回填了元数据），供 cover_service 判断。
  static Future<bool> fetchRemoteCover(Song song) async {
    // STRM 歌的 davPath 为空，用 Resolver 落地的目标地址
    final davPath = song.davPath ?? (song.isStrm ? song.targetUri : null);
    if (davPath == null || davPath.isEmpty) return false;
    if (song.coverUrl != null && !needsMetadata(song)) return false;
    final url = fullUrlFor(davPath);
    if (url == null) return false;
    final hadCover = song.coverUrl != null;
    final neededMeta = needsMetadata(song);
    try {
      final head = await readRemoteBytes(url, 1024 * 1024);
      if (head.isEmpty) return false;
      await _extractCoverFromBytes(song, davPath, head);
      // 头部拿不到完整元数据（moov 在尾部）：读尾 1MB 拼接头+尾再解析。
      // lofty 解析 MP4 需要文件头的 ftyp + 尾部的 moov，纯尾部字节无法探测。
      if (needsMetadata(song)) {
        final tail = await readRemoteBytes(url, 1024 * 1024, suffix: true);
        if (tail.isNotEmpty) {
          await _extractCoverFromBytes(song, davPath, [...head, ...tail]);
        }
      }
    } catch (e) {
      Log.w('WebDAV', '封面提取失败 ($davPath): $e');
      return false;
    }
    return (song.coverUrl != null && !hadCover) ||
        (neededMeta && !needsMetadata(song));
  }

  /// 从远端读到的字节解析内嵌封面：写带真实扩展名的临时文件（lofty 按
  /// 扩展名探测格式），成功后写 .covers 缓存。返回是否解析到封面。
  static Future<bool> _extractCoverFromBytes(
    Song song,
    String davPath,
    List<int> bytes,
  ) async {
    final appDir = await getApplicationDocumentsDirectory();
    final headDir = Directory('${appDir.path}/.dav_head');
    if (!await headDir.exists()) await headDir.create(recursive: true);
    final ext = davPath.split('.').last.toLowerCase();
    final headFile = File('${headDir.path}/${davPath.hashCode}.$ext');
    await headFile.writeAsBytes(bytes);
    try {
      final meta = await rs.readMetadata(headFile.path);
      // 元数据回填：解析出的 album/artist/时长顺手覆盖占位值（幂等）
      _backfillMetadata(song, meta);
      if (meta.hasCover && meta.coverBytes.isNotEmpty && song.coverUrl == null) {
        final coversDir = Directory('${appDir.path}/.covers');
        if (!await coversDir.exists()) await coversDir.create(recursive: true);
        final coverFile =
            File('${coversDir.path}/dav_${davPath.hashCode}.jpg');
        await coverFile.writeAsBytes(meta.coverBytes);
        song.coverUrl = coverFile.path;
        song.hasCover = true;
        return true;
      }
    } catch (e) {
      Log.v('WebDAV', '封面字节解析失败 ($davPath): $e');
    } finally {
      if (await headFile.exists()) await headFile.delete();
    }
    return false;
  }

  /// 元数据占位回填：仅覆盖仍为占位值的字段（album/artist/估算时长），
  /// 已有真实值不动（与 SMB _backfillMetadata 一致）。
  static void _backfillMetadata(Song song, MetadataResult meta) {
    final album = meta.album;
    if (song.album == albumPlaceholder && album != null && album.isNotEmpty) {
      song.album = album;
    }
    final artist = meta.artist;
    if (song.artist == artistPlaceholder && artist != null && artist.isNotEmpty) {
      song.artist = artist;
    }
    if (song.durationEstimated && meta.durationSecs > 0) {
      song.duration =
          Duration(milliseconds: (meta.durationSecs * 1000).round());
      song.durationEstimated = false;
    }
  }

  /// 远端歌词：读取与音频同目录同名的 .lrc/.LRC（小文本，Range 读前部
  /// 即全文）。失败（文件不存在/读取失败）返回 null。
  /// 两个扩展名并行探测，省一个 HTTP 往返。
  static Future<String?> fetchRemoteLyrics(String davPath) async {
    final base = davPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final results = await Future.wait([
      for (final ext in const ['.lrc', '.LRC'])
        _tryReadLrcUrl(fullUrlFor('$base$ext')),
    ]);
    for (final r in results) {
      if (r != null) return r;
    }
    return null;
  }

  static Future<String?> _tryReadLrcUrl(String? url) async {
    if (url == null) return null;
    try {
      final bytes = await readRemoteBytes(url, 512 * 1024);
      if (bytes.isEmpty) return null;
      return decodeLrcBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 读取远端文本文件内容（STRM 指针解析用），失败/为空返回 null。
  static Future<String?> readRemoteText(String davPath) async {
    try {
      final client = await _ensureClient();
      if (client == null) return null;
      final bytes = await client
          .read(davPath)
          .timeout(const Duration(seconds: 30));
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      Log.w('WebDAV', 'readRemoteText failed ($davPath): $e');
      return null;
    }
  }

  /// 检查单曲本地缓存是否已就绪（存在且非空才命中）。
  static Future<String?> cachedLocalPath(String davPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.webdav_cache');
      if (!await cacheDir.exists()) return null;
      final name = davPath.split('/').last;
      final localFile = File('${cacheDir.path}/${davPath.hashCode}_$name');
      if (await localFile.exists() && await localFile.length() > 0) {
        Log.d('WebDAV', '缓存命中: $name');
        return localFile.path;
      }
      return null;
    } catch (e) {
      Log.e('WebDAV', 'cachedLocalPath failed: $e');
      return null;
    }
  }

  /// 下载单曲到本地缓存，返回可播放路径；失败返回 null。
  /// 并发调用按 davPath 去重，共享同一次下载。
  /// [onProgress] 可选回调，参数为已下载字节数与总字节数（总长未知时为 -1）。
  static Future<String?> downloadToLocal(
    String davPath, {
    void Function(int count, int total)? onProgress,
  }) async {
    final existing = _downloading[davPath];
    if (existing != null) {
      Log.d('WebDAV', '下载已在进行中，共享任务: $davPath');
      return existing;
    }
    final future = _downloadToLocalImpl(davPath, onProgress);
    _downloading[davPath] = future;
    try {
      return await future;
    } finally {
      _downloading.remove(davPath);
    }
  }

  static Future<String?> _downloadToLocalImpl(
    String davPath,
    void Function(int count, int total)? onProgress,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.webdav_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = davPath.split('/').last;
      final localFile = File('${cacheDir.path}/${davPath.hashCode}_$name');
      if (await localFile.exists() && await localFile.length() > 0) {
        Log.d('WebDAV', '下载前缓存命中: $name');
        return localFile.path;
      }
      final client = await _ensureClient();
      if (client == null) return null;
      Log.i('WebDAV', '开始下载: $name');
      // 先写临时文件再原子改名：避免失败时残留半截缓存被后续误命中
      final tmpFile = File('${localFile.path}.part');
      // 优先并发分片下载（Range 并行拉满带宽）；失败回退 webdav_client 顺序下载
      if (!await _downloadParallel(davPath, tmpFile, onProgress)) {
        try {
          await client
              .read2File(davPath, tmpFile.path, onProgress: onProgress)
              .timeout(const Duration(minutes: 5));
        } catch (e) {
          Log.e('WebDAV', 'read2File failed ($davPath): $e');
          if (await tmpFile.exists()) await tmpFile.delete();
          return null;
        }
      }
      // 下载完整性校验：文件缺失或空文件均视为失败，不留半截缓存
      if (!await tmpFile.exists() || await tmpFile.length() == 0) {
        if (await tmpFile.exists()) await tmpFile.delete();
        Log.w('WebDAV', '下载结果为空文件 ($davPath)');
        return null;
      }
      await tmpFile.rename(localFile.path);
      final mb = await localFile.length() / 1024 / 1024;
      final secs = sw.elapsedMilliseconds / 1000;
      Log.i(
        'WebDAV',
        '下载完成: $name（${mb.toStringAsFixed(1)}MB，'
            '${sw.elapsedMilliseconds}ms'
            '${secs > 0 ? '，${(mb / secs).toStringAsFixed(1)}MB/s' : ''}）',
      );
      return localFile.path;
    } catch (e) {
      Log.e('WebDAV', 'downloadToLocal failed ($davPath): $e');
      return null;
    }
  }

  /// 并发分片下载：先探远端文件大小，按 [ParallelChunks] 片均分，
  /// 每片发独立 Range 请求（Rust reqwest 连接并行）写 `.part.N` 临时
  /// 文件，最后按序拼接。比 webdav_client 单连接顺序读快。
  /// 服务器不支持 Range / 大小未知 / 任一片失败 → 返回 false 回退顺序下载。
  static const int _parallelChunks = 4;

  static Future<bool> _downloadParallel(
    String davPath,
    File tmpFile,
    void Function(int count, int total)? onProgress,
  ) async {
    final url = fullUrlFor(davPath);
    if (url == null) return false;
    final partFiles = <File>[];
    try {
      final total = await rs.webdavFileSize(
        url: url,
        username: username,
        password: password,
      );
      if (total <= 0) return false;
      final size = total.toInt();
      final chunkSize = (size + _parallelChunks - 1) ~/ _parallelChunks;
      await Future.wait([
        for (var i = 0; i < _parallelChunks; i++)
          () async {
            final start = i * chunkSize;
            if (start >= size) return;
            final len = math.min(chunkSize, size - start);
            final data = await rs.webdavDownloadRange(
              url: url,
              username: username,
              password: password,
              offset: start,
              maxLen: len,
            );
            if (data.isEmpty) throw StateError('分片 $i 读取为空');
            final part = File('${tmpFile.path}.$i');
            try {
              await part.writeAsBytes(data, flush: true);
            } catch (_) {
              // 写入失败：立即清理本片，避免残留（该片可能被部分写入）
              try {
                if (await part.exists()) await part.delete();
              } catch (_) {}
              rethrow;
            }
            partFiles.add(part);
          }(),
      ]);
      final sink = tmpFile.openWrite();
      try {
        var written = 0;
        for (final part in partFiles) {
          await sink.addStream(part.openRead());
          written += await part.length();
          onProgress?.call(written, size);
        }
      } finally {
        await sink.close();
      }
      return true;
    } catch (e) {
      Log.w('WebDAV', '并发分片下载失败，回退顺序下载 ($davPath): $e');
      return false;
    } finally {
      for (final part in partFiles) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }
}
