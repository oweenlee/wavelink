import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as wd;
import '../../domain/models/song.dart';
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';
import 'log.dart';
import 'preferences_service.dart';

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
      lastError = '$e';
      Log.e(
        'WebDAV',
        'testConnection failed (${sw.elapsedMilliseconds}ms): $e',
      );
      return lastError;
    }
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
        final song = _toSong(entry);
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
  static Song? _toSong(wd.File entry) {
    final name = entry.name ?? '';
    final path = entry.path ?? '';
    if (name.isEmpty || path.isEmpty) return null;
    final ext = name.split('.').last.toLowerCase();
    if (!ImportService.extensions.contains(ext)) return null;
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
      try {
        await client
            .read2File(davPath, tmpFile.path, onProgress: onProgress)
            .timeout(const Duration(minutes: 5));
      } catch (e) {
        Log.e('WebDAV', 'read2File failed ($davPath): $e');
        if (await tmpFile.exists()) await tmpFile.delete();
        return null;
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
}
