import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/song.dart';
import '../../src/rust/api/smb.dart' as smb;
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';
import 'preferences_service.dart';
import 'rust_service.dart' as rs;
import 'log.dart';

/// SMB 直挂服务
///
/// 基于 Rust `smb2` crate（经 flutter_rust_bridge 绑定）直接访问 NAS 共享目录，
/// 扫描、读取文件并将音频导入本地。空用户名/密码即 guest（匿名）访问。
class SmbService {
  SmbService._();

  static bool _connected = false;

  /// 当前已挂载的共享名（connectShare 成功时记录；会话重建/断开时清空）。
  /// 避免每次下载重复挂载 tree。
  static String? _mountedShare;

  /// 扫描进行中标记：期间禁止 connect/disconnect 重建或销毁会话，
  /// 否则扫描中的 read 会因 tree 被重置而报 "no share connected"。
  static bool _scanning = false;

  /// 会话恢复互斥锁：并发任务（批量封面提取等）同时失败时，
  /// 只允许一个执行强制重连，其余等待后复用新会话。
  /// 无此锁时每个失败任务各自 smbConnect，互相摧毁对方正在使用的
  /// 会话/连接池，报 Protocol error 雪崩、全部封面提取失败。
  static Future<void>? _recovering;

  /// ensureReady 单飞锁：并发任务（批量封面提取等）同时看到未连接时，
  /// 只允许一个执行 connect + connectShare，其余等待并复用结果。
  /// 无此锁时每个任务各自 smbConnect 重建会话/连接池，互相覆盖，
  /// 新池连接未挂载共享就被读取 → 全部报 "no share connected"。
  static Future<bool>? _ensuring;

  /// connect 单飞锁：并发 connect（ensureReady 之外的入口如设置页
  /// 测试连接 + 后台补提取同时发起）各自 smbConnect 会互相覆盖会话。
  static Future<bool>? _connecting;

  /// 进行中的下载（按 smbPath 去重）：并发调用共享同一次下载，
  /// 避免两个任务写同一个 .part 文件互相截断，以及各自失败后
  /// 各自强制重连互相摧毁会话。
  static final Map<String, Future<String?>> _downloading = {};

  /// 最近一次操作的具体错误信息（用于 UI 展示排查）
  static String? lastError;

  static bool get isConnected => _connected;

  /// 连接 SMB 服务器（host 为裸 IP/域名，内部拼 :port）。
  /// 共享挂载在扫描/列目录前按需调用 [connectShare]。
  /// 单飞：同参数的并发连接共享同一次过程。
  static Future<bool> connect({
    required String host,
    required String username,
    required String password,
    String domain = '',
    int port = 445,
  }) async {
    final pending = _connecting;
    if (pending != null) return pending;
    final fut = _connectImpl(
      host: host,
      username: username,
      password: password,
      domain: domain,
      port: port,
    );
    _connecting = fut;
    try {
      return await fut;
    } finally {
      _connecting = null;
    }
  }

  static Future<bool> _connectImpl({
    required String host,
    required String username,
    required String password,
    String domain = '',
    int port = 445,
  }) async {
    // 扫描进行中：复用现有会话，不重建（重建会把 tree 重置为 None）
    if (_scanning && _connected) return true;
    // 连接前网络检测：无网络直接给明确提示，不甩 "No route to host" 原始错误
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.isEmpty || connectivity.contains(ConnectivityResult.none)) {
      _connected = false;
      lastError = '未连接网络：请先连上 Wi-Fi（需与 NAS 同一局域网）';
      return false;
    }
    try {
      await smb.smbConnect(
        host: host,
        port: port,
        username: username,
        password: password,
        domain: domain,
      );
      _connected = true;
      // 会话重建后 tree 被重置，需重新 connectShare 才能读文件
      _mountedShare = null;
      lastError = null;
      return true;
    } catch (e) {
      Log.e('SMB', 'connect failed: $e');
      _connected = false;
      lastError = _friendlyConnectError('$e');
      return false;
    }
  }

  /// 挂载共享（后续 list/read 均相对该共享根目录）
  /// 连接错误人性化：把底层 I/O 错误映射成可操作的提示。
  /// iOS 本地网络权限无 API 可查（被拒时系统直接阻断连接，报
  /// No route to host 等），只能引导去设置开启。
  static String _friendlyConnectError(String raw) {
    if (raw.contains('No route to host') || raw.contains('Network is unreachable')) {
      return Platform.isIOS
          ? '$raw\n\n无法到达主机：请确认 iPhone 已连上与 NAS 同一局域网的 Wi-Fi；'
            '若首次连接弹出过“本地网络”权限提示请点允许，'
            '若之前拒绝过，请到 设置 > 隐私与安全性 > 本地网络 中开启 WaveLink。'
          : '$raw\n\n无法到达主机：请确认手机与 NAS 在同一局域网。';
    }
    if (raw.toLowerCase().contains('timed out') || raw.toLowerCase().contains('timeout')) {
      return '$raw\n\n连接超时：请确认 NAS 已开机、SMB/文件共享已开启，且手机与 NAS 在同一局域网。';
    }
    return raw;
  }

  static Future<bool> connectShare(String shareName) async {
    if (!_connected) return false;
    try {
      await smb.smbConnectShare(shareName: shareName);
      _mountedShare = shareName;
      lastError = null;
      return true;
    } catch (e) {
      Log.e('SMB', 'connectShare $shareName failed: $e');
      lastError = '$e';
      return false;
    }
  }

  /// 保证 SMB 会话可用（播放/下载前的自愈入口）：
  /// 未连接时用已保存的配置自动重连（测试连接后 disconnect、重启后
  /// 会话未恢复等场景），并确保共享 tree 已挂载。返回是否就绪。
  /// 单飞：并发调用共享同一次重连过程，避免会话互相覆盖。
  static Future<bool> ensureReady() async {
    final pending = _ensuring;
    if (pending != null) return pending;
    final fut = _ensureReadyImpl();
    _ensuring = fut;
    try {
      return await fut;
    } finally {
      _ensuring = null;
    }
  }

  static Future<bool> _ensureReadyImpl() async {
    if (!_connected) {
      final prefs = PreferencesService.instance;
      final host = prefs.nasHost;
      if (host == null || host.isEmpty) {
        Log.e('SMB', 'ensureReady 失败：未配置 NAS host');
        return false;
      }
      final ok = await connect(
        host: host,
        username: prefs.nasUsername ?? '',
        password: prefs.nasPassword,
      );
      if (!ok) return false;
    }
    final sharePath = PreferencesService.instance.nasShare;
    if (sharePath == null || sharePath.isEmpty) {
      Log.e('SMB', 'ensureReady 失败：未配置 NAS 共享');
      return false;
    }
    // 与 scanSmbLibrary 对齐：nasShare 可能填“共享名/子目录”，
    // connectShare 只接受共享名（第一段），否则挂载失败导致无法播放。
    final parts = sharePath.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      Log.e('SMB', 'ensureReady 失败：共享路径无效 ($sharePath)');
      return false;
    }
    final shareName = parts.first;
    // 已挂载同一共享则复用，否则（会话重建/首次）挂载
    if (_mountedShare == shareName) return true;
    final ok = await connectShare(shareName);
    if (!ok) {
      Log.e('SMB', 'ensureReady 失败：connectShare($shareName) 未成功: $lastError');
    }
    return ok;
  }

  static Future<void> disconnect() async {
    // 扫描进行中：保持会话，避免打断扫描
    if (_scanning) return;
    try {
      await smb.smbDisconnect();
    } catch (e) {
      Log.e('SMB', 'disconnect failed: $e');
    }
    _connected = false;
    _mountedShare = null;
  }

  /// 列出服务器所有共享（返回共享名）
  static Future<List<String>> listShares() async {
    if (!_connected) return [];
    try {
      final shares = await smb.smbListShares();
      return shares.map((s) => s.name).toList();
    } catch (e) {
      Log.e('SMB', 'listShares failed: $e');
      return [];
    }
  }

  /// 列出共享内目录内容
  static Future<List<smb.SmbDirEntry>> listFiles(String path) async {
    if (!_connected) return [];
    try {
      return await smb.smbListDirectory(path: path);
    } catch (e) {
      Log.e('SMB', 'listFiles($path) failed: $e');
      return [];
    }
  }

  /// 递归扫描 SMB 共享目录中的音频文件。
  /// [sharePath] 如 "/misic" 或 "/misic/Music"：首段为共享名，其余为共享内相对路径。
  /// [onBatch] 增量回调：每下载满一批（20 首）立即回调，
  /// 供上层实时合并入库/持久化，避免全量扫完才可见。
  static Future<List<Song>> scanSmbLibrary(
    String sharePath, {
    void Function(List<Song> batch)? onBatch,
  }) async {
    if (!_connected) return [];

    final parts = sharePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return [];
    final shareName = parts.first;
    final root = parts.skip(1).join('/');

    if (!await connectShare(shareName)) return [];

    _scanning = true;
    final songs = <Song>[];
    try {
      await _scanDirectory(root, songs, onBatch);
    } catch (e) {
      Log.e('SMB', 'scanSmbLibrary failed: $e');
    } finally {
      _scanning = false;
    }
    return songs;
  }

  static Future<void> _scanDirectory(
    String relPath,
    List<Song> songs, [
    void Function(List<Song> batch)? onBatch,
  ]) async {
    try {
      final entries = await smb.smbListDirectory(path: relPath);
      final dirs = <String>[];
      final files = <(String, String, int)>[];
      for (final entry in entries) {
        // 防御：跳过 "."/".."（Rust 层已过滤，此处兜底）
        if (entry.name == '.' || entry.name == '..') continue;
        final childPath = relPath.isEmpty ? entry.name : '$relPath/${entry.name}';
        if (entry.isDir) {
          dirs.add(childPath);
        } else if (_isAudio(entry.name)) {
          files.add((childPath, entry.name, entry.size.toInt()));
        }
      }
      // 子目录串行递归（保持目录遍历顺序稳定），文件并行下载但结果按
      // 列表顺序收集——并发 worker 按完成顺序 add 会导致每次扫描排序不同。
      final buffer = <Song>[];
      void flush() {
        if (buffer.isNotEmpty) {
          onBatch?.call(List.of(buffer));
          buffer.clear();
        }
      }

      for (final d in dirs) {
        await _scanDirectory(d, songs, onBatch);
      }

      // 并行下载，结果按下标收集后按序输出（顺序与目录条目一致）
      final results = List<Song?>.filled(files.length, null);
      var next = 0;
      Future<void> worker() async {
        while (next < files.length) {
          final i = next++;
          final f = files[i];
          results[i] = await _smbFileToSong(f.$1, f.$2, f.$3);
        }
      }
      await Future.wait(List.generate(8, (_) => worker()));
      for (final s in results) {
        if (s != null) {
          songs.add(s);
          buffer.add(s);
          if (buffer.length >= 20) flush();
        }
      }
      flush();
    } catch (e) {
      Log.e('SMB', 'scan directory $relPath failed: $e');
    }
  }

  static bool _isAudio(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ImportService.extensions.contains(ext);
  }

  /// 将 SMB 文件转为可播放的 Song 对象。
  /// 离线缓存关闭（默认）：只建索引，不下载文件，播放时按需下载；
  /// 离线缓存开启：下载文件到本地 `.smb_cache` 并读取真实元数据，关 SMB 也能播。
  static Future<Song?> _smbFileToSong(
    String smbPath,
    String name,
    int remoteSize,
  ) async {
    final fallbackTitle = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    // 文件名启发式解析艺术家（`艺术家 - 歌名` 格式），拆不到时保持占位由 UI 隐藏
    final parsed = ImportService.parseArtistTitle(fallbackTitle);

    // 关闭离线缓存 → 仅索引，不占本地空间。播放时经 downloadToLocal 拉取。
    if (!PreferencesService.instance.smbOfflineCache) {
      return Song(
        id: 'smb_${smbPath.hashCode}',
        title: parsed.title,
        artist: parsed.artist ?? 'Unknown Artist',
        album: 'NAS Music',
        duration: ImportService.estimateDuration(remoteSize, name),
        dominantColor: AppTheme.s2,
        smbPath: smbPath,
        durationEstimated: true,
      );
    }

    try {
      // 下载到本地缓存（按远端大小判断是否有变化）
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.smb_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final localFile = File('${cacheDir.path}/${smbPath.hashCode}_$name');

      String localPath;
      final cached = await localFile.exists();
      final cachedSize = cached ? await localFile.length() : 0;
      if (cached && cachedSize > 0 && cachedSize == remoteSize) {
        localPath = localFile.path;
      } else {
        // 流式下载到本地（Rust 分块经 FRB stream 推送，边收边写，避免整文件进内存）
        final sink = localFile.openWrite();
        try {
          await for (final chunk in smb.smbReadFileStream(path: smbPath)) {
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        localPath = localFile.path;
      }

      // 用 Rust 读取真实元数据
      String title = fallbackTitle;
      String artist = 'Unknown Artist';
      String album = 'NAS Music';
      Duration duration = ImportService.estimateDuration(
        await localFile.length(),
        localPath,
      );
      bool durationEstimated = true;
      String? coverUrl;
      bool hasCover = false;

      if (rs.rustAvailable) {
        try {
          final meta = await rs.readMetadata(localPath);
          if (meta.title != null && meta.title!.isNotEmpty) title = meta.title!;
          if (meta.artist != null && meta.artist!.isNotEmpty) artist = meta.artist!;
          if (meta.album != null && meta.album!.isNotEmpty) album = meta.album!;
          if (meta.durationSecs > 0) {
            duration = Duration(milliseconds: (meta.durationSecs * 1000).round());
            durationEstimated = false;
          }
          if (meta.hasCover && meta.coverBytes.isNotEmpty) {
            final coversDir = Directory('${appDir.path}/.covers');
            if (!await coversDir.exists()) await coversDir.create(recursive: true);
            final coverFile = File('${coversDir.path}/smb_${smbPath.hashCode}.jpg');
            await coverFile.writeAsBytes(meta.coverBytes);
            coverUrl = coverFile.path;
            hasCover = true;
          }
        } catch (e) {
          Log.e('SMB', 'Rust 元数据读取失败: $e');
        }
      }

      return Song(
        id: 'smb_${smbPath.hashCode}',
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        dominantColor: AppTheme.s2,
        smbPath: smbPath,
        path: localPath,
        coverUrl: coverUrl,
        hasCover: hasCover,
        durationEstimated: durationEstimated,
      );
    } catch (e) {
      // 降级：下载/元数据提取失败，返回 null 跳过该文件
      Log.e('SMB', '文件处理失败 ($smbPath): $e');
      return null;
    }
  }

  /// 读 SMB 远端文件头部提取内嵌封面（离线缓存关模式：不下载整文件）。
  /// 成功设置 song.coverUrl/hasCover；失败静默（封面保持纯色占位）。
  /// 会话可能已断开（服务器空闲超时、iOS 后台回收等）：
  /// 首次尝试前先自愈就绪，失败后强制重连再试一次。
  static Future<void> fetchRemoteCover(Song song) async {
    final smbPath = song.smbPath;
    if (smbPath == null || smbPath.isEmpty || song.coverUrl != null) return;
    // App 后台挂起后 SMB 会话常已失效而 _connected 仍为 true，
    // 直接读会失败；先走自愈入口确保会话与共享挂载就绪
    if (!await ensureReady()) return;
    try {
      await _fetchRemoteCoverOnce(song, smbPath);
    } catch (e) {
      Log.w('SMB', '远端封面提取失败 ($e)，强制重连后重试');
      if (!await _recoverSession()) {
        Log.e('SMB', '封面重试中止：重连失败');
        return;
      }
      try {
        await _fetchRemoteCoverOnce(song, smbPath);
      } catch (e2) {
        Log.e('SMB', '远端封面提取重试仍失败: $e2');
      }
    }
  }

  /// 强制全量重连（互斥）：并发失败的多个任务共享一次重连，
  /// 避免各自 smbConnect 互相摧毁对方仍在使用的会话（Protocol error 雪崩）。
  static Future<bool> _recoverSession() async {
    final pending = _recovering;
    if (pending != null) {
      await pending;
      return _connected;
    }
    final fut = () async {
      _connected = false;
      _mountedShare = null;
      await ensureReady();
    }();
    _recovering = fut;
    try {
      await fut;
    } finally {
      _recovering = null;
    }
    return _connected;
  }

  static Future<void> _fetchRemoteCoverOnce(Song song, String smbPath) async {
    // 1MB：FLAC 前置 metadata 块/大尺寸 ID3v2 内嵌封面可能超 512KB，
    // 截断后标签解析失败导致封面静默丢失
    final head = await smb.smbReadHead(
      path: smbPath,
      maxLen: BigInt.from(1024 * 1024),
    );
    if (head.isEmpty) return;
    final appDir = await getApplicationDocumentsDirectory();
    final headDir = Directory('${appDir.path}/.smb_head');
    if (!await headDir.exists()) await headDir.create(recursive: true);
    // 必须保留真实音频扩展名：lofty/symphonia 按扩展名探测格式，
    // 未知后缀会直接探测失败，封面静默丢失（历史 bug：用 .head）
    final ext = smbPath.split('.').last.toLowerCase();
    final headFile = File('${headDir.path}/${smbPath.hashCode}.$ext');
    await headFile.writeAsBytes(head);
    try {
      final meta = await rs.readMetadata(headFile.path);
      if (meta.hasCover && meta.coverBytes.isNotEmpty) {
        final coversDir = Directory('${appDir.path}/.covers');
        if (!await coversDir.exists()) await coversDir.create(recursive: true);
        final coverFile =
            File('${coversDir.path}/smb_${smbPath.hashCode}.jpg');
        await coverFile.writeAsBytes(meta.coverBytes);
        song.coverUrl = coverFile.path;
        song.hasCover = true;
      }
    } finally {
      // 头部临时文件用完即删
      if (await headFile.exists()) await headFile.delete();
    }
  }

  /// 播放时按需下载单曲到本地缓存，返回可播放的本地路径（已存在则直接复用）。
  /// 用于离线缓存关闭时按需拉取；缓存复用避免重复下载。
  /// 同一 smbPath 的并发调用去重：共享同一次下载，避免 .part 写入竞态。
  static Future<String?> downloadToLocal(String smbPath) async {
    if (smbPath.isEmpty) return null;
    final pending = _downloading[smbPath];
    if (pending != null) return pending;
    final fut = _downloadToLocalImpl(smbPath);
    _downloading[smbPath] = fut;
    try {
      return await fut;
    } finally {
      _downloading.remove(smbPath);
    }
  }

  static Future<String?> _downloadToLocalImpl(String smbPath) async {
    if (smbPath.isEmpty) return null;
    // 自愈：会话丢失（测试连接断开/重启等）时自动重连并挂载共享
    if (!await ensureReady()) {
      Log.e('SMB', 'downloadToLocal 中止：会话不可用 (lastError=$lastError)');
      return null;
    }
    var path = await _doDownload(smbPath);
    if (path == null) {
      // 下载失败：连接可能已失效（尤其 iOS 后台回收后，缓存的 _mountedShare
      // 会误判为就绪）。强制全量重连 + 重新挂载后重试一次。
      Log.w('SMB', '首次下载失败，强制重连后重试 ($smbPath)');
      _connected = false;
      _mountedShare = null;
      if (await ensureReady()) {
        path = await _doDownload(smbPath);
      }
    }
    return path;
  }

  /// 实际下载单曲到本地缓存，返回可播放路径；失败返回 null。
  static Future<String?> _doDownload(String smbPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.smb_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = smbPath.split('/').last;
      final localFile = File('${cacheDir.path}/${smbPath.hashCode}_$name');
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      // 先写临时文件再原子改名：避免失败时残留半截缓存被后续误命中
      final tmpFile = File('${localFile.path}.part');
      final sink = tmpFile.openWrite();
      try {
        await for (final chunk in smb.smbReadFileStream(path: smbPath)) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      // 下载完整性校验：文件缺失（会话断开时一个分片都没收到）
      // 或空文件均视为失败，不留下半截缓存
      if (!await tmpFile.exists() || await tmpFile.length() == 0) {
        if (await tmpFile.exists()) await tmpFile.delete();
        Log.w('SMB', '下载结果为空文件 ($smbPath)');
        return null;
      }
      await tmpFile.rename(localFile.path);
      return localFile.path;
    } catch (e) {
      Log.e('SMB', 'downloadToLocal failed ($smbPath): $e');
      return null;
    }
  }

  /// 从 NAS 读取音频文件并复制到本地 Documents/Imported/
  static Future<String?> copyToLocal(String smbPath) async {
    if (!await ensureReady()) return null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final importDir = Directory('${appDir.path}/Imported');
      if (!await importDir.exists()) await importDir.create(recursive: true);

      final name = smbPath.split('/').last;
      final dest = File('${importDir.path}/$name');

      if (await dest.exists()) return dest.path;

      final sink = dest.openWrite();
      try {
        await for (final chunk in smb.smbReadFileStream(path: smbPath)) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      return dest.path;
    } catch (e) {
      Log.e('SMB', 'copyToLocal failed: $e');
      return null;
    }
  }
}
