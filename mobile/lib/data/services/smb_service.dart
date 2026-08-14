import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/song.dart';
import '../../src/rust/api/metadata.dart' show MetadataResult;
import '../../src/rust/api/smb.dart' as smb;
import '../../ui/core/theme/app_theme.dart';
import 'import_service.dart';
import 'lrc_codec.dart';
import 'log.dart';
import 'preferences_service.dart';
import 'rust_service.dart' as rs;
import 'strm_resolver.dart';

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

  /// 封面提取连续失败计数（会话级熔断）。死会话上批量封面提取
  /// 每条都白等 10s 再重建，实测 6~8 条连刷；计数达阈值后停止
  /// 逐条重试，先主动重建一次再继续。
  static int _coverFailStreak = 0;
  static const int _coverFailThreshold = 3;

  /// 封面熔断冷却：达到熔断阈值后暂停封面提取一段时间，
  /// 避免死会话上批间无冷却反复刷超时（历史日志：连续 4 轮
  /// 封面批每轮都 10s 超时熔断，期间播放/下载被连接竞争拖垮）。
  static DateTime _coverCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 熔断冷却是否生效（封面提取暂停中）。
  static bool get coverCooldownActive =>
      DateTime.now().isBefore(_coverCooldownUntil);

  /// 播放/下载活动计数 + 最近活动时间：封面提取（后台低优先级任务）
  /// 在播放/下载进行时让路，避免与播放竞争 NAS 连接数（历史事故：
  /// 封面批在跑时点歌，喂流拿不到连接 → 3s 超时杀流 → 回退下载
  /// 又撞封面批 → 点歌 34s 才出声）。
  static int _activePlayback = 0;
  static DateTime _lastPlaybackAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放/下载是否活跃（含 5s 余量窗口，覆盖 playSmbStream 后台喂流期）。
  static bool get playbackActive =>
      _activePlayback > 0 ||
      DateTime.now().difference(_lastPlaybackAt).inSeconds < 5;

  static void enterPlayback() {
    _activePlayback++;
    _lastPlaybackAt = DateTime.now();
  }

  static void exitPlayback() {
    if (_activePlayback > 0) _activePlayback--;
    _lastPlaybackAt = DateTime.now();
  }

  // ── 会话守卫：所有会话变更（连接/重连/挂载/断开）的唯一串行入口 ──
  //
  // 历史教训：并发任务各自重建会话互相摧毁（Protocol error 雪崩、
  // "no share connected" 刷屏），此前用 _connecting/_ensuring/_recovering
  // 三个重叠的单飞锁补丁修复，语义纠缠难以维护。现收敛为：
  // - _gate：异步互斥，会话变更串行化，并发调用排队复用同一过程；
  // - _sessionGen：会话代数，每次会话变更（重建/断开）+1。失败方
  //   重连前对比发起时的代数，若已被其他任务重建过则跳过重连
  //   直接重试，避免重复摧毁刚建好的会话。
  static Future<void> _gate = Future.value();
  static int _sessionGen = 0;

  /// 在会话守卫内串行执行 [op]（会话变更类操作的唯一入口）。
  static Future<T> _inGate<T>(Future<T> Function() op) {
    final prev = _gate;
    final next = prev.catchError((_) {}).then((_) => op());
    _gate = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// 进行中的下载（按 smbPath 去重）：并发调用共享同一次下载，
  /// 避免两个任务写同一个 .part 文件互相截断，以及各自失败后
  /// 各自强制重连互相摧毁会话。
  static final Map<String, Future<String?>> _downloading = {};

  /// 最近一次操作的具体错误信息（用于 UI 展示排查）
  static String? lastError;

  /// 扫描期元数据占位标记（离线缓存关时不读元数据，统一用这些值占位）。
  /// 远端封面提取时据此判断"需回填真实元数据"。
  static const albumPlaceholder = 'NAS Music';
  static const artistPlaceholder = 'Unknown Artist';

  /// 元数据是否仍为扫描期占位值：离线缓存关（默认）时扫描只按
  /// 文件名建索引，album/artist 统一占位，导致 700+ 首歌全挤在
  /// 一张"NAS Music"里。远端读头提取封面时一并回填真实值。
  static bool needsMetadata(Song song) =>
      song.album == albumPlaceholder ||
      song.artist == artistPlaceholder ||
      song.durationEstimated;

  /// 前台保活定时器：防止 NAS 会话空闲超时回收闲置连接。
  /// smb2 crate 只探测"请求在途但线路静默"的连接，完全空闲的
  /// 连接从不被探测，被 NAS 悄悄回收后下次 IO 白等 30s 才判死。
  /// 定时器每个 tick 发一条 fs_info 轻请求，让每条连接保持活跃。
  static Timer? _keepaliveTimer;

  static bool get isConnected => _connected;

  /// 启动前台保活（幂等）：已有定时器则不重复创建。连接/重建
  /// 成功后由 [ensureReady] 链路调用。
  static void startKeepalive() {
    if (_keepaliveTimer?.isActive == true) return;
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // 已断开则不空转；保活本身轻量，直接静默执行
      if (!_connected) return;
      _keepaliveTick();
    });
  }

  /// 停止前台保活：断开连接时调用。
  static void stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  /// 一次保活：探活返回 false（任一连接失败/超时）说明连接已被
  /// NAS/网络回收，主动 force 重建，把 30s 判死消化在后台定时器里，
  /// 而不是下一次真实 IO 上。早期 Rust 侧吞错导致探活永远"成功"，
  /// 死连接无人清理——现在探活结果真实上报。
  static Future<void> _keepaliveTick() async {
    bool healthy;
    try {
      healthy = await smb.smbKeepalive();
    } catch (e) {
      Log.w('SMB', '保活探测异常($e)，主动重建会话');
      healthy = false;
    }
    if (healthy) return;
    Log.w('SMB', '保活探测发现死连接，主动重建会话');
    // 重建失败（NAS 真下线）则停掉定时器，避免每 30s 空转重连
    final ok = await ensureReady(force: true);
    if (!ok) stopKeepalive();
  }

  /// 批量任务前的会话健康闸门：探活（单条 5s 超时）发现死连接先
  /// force 重建，避免整批请求同时踩死连接各白等超时。返回是否可用。
  static Future<bool> ensureHealthy() async {
    if (!_connected) return false;
    bool healthy;
    try {
      healthy = await smb.smbKeepalive();
    } catch (e) {
      Log.w('SMB', '批前探活异常($e)，主动重建会话');
      healthy = false;
    }
    if (healthy) return true;
    Log.w('SMB', '批前探活发现死连接，主动重建会话');
    return ensureReady(force: true);
  }

  /// 连接 SMB 服务器（host 为裸 IP/域名，内部拼 :port）。
  /// 共享挂载在扫描/列目录前按需调用 [connectShare]。
  /// 会话守卫内串行：并发连接排队复用同一过程，不互相覆盖。
  static Future<bool> connect({
    required String host,
    required String username,
    required String password,
    String domain = '',
    int port = 445,
  }) =>
      _inGate(() => _connectImpl(
        host: host,
        username: username,
        password: password,
        domain: domain,
        port: port,
      ));

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
      _sessionGen++;
      lastError = null;
      startKeepalive();
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

  /// 保证 SMB 会话可用（播放/下载前的唯一自愈入口）：
  /// 未连接时用已保存的配置自动重连（测试连接后 disconnect、重启后
  /// 会话未恢复等场景），并确保共享 tree 已挂载。返回是否就绪。
  /// [force]=true：忽略缓存的 _connected/_mountedShare 强制重建
  ///（操作失败后判定会话失效时使用）。会话守卫内串行。
  static Future<bool> ensureReady({bool force = false}) async {
    final ok = await _inGate(() => _ensureReadyImpl(force: force));
    if (ok) startKeepalive();
    return ok;
  }

  static Future<bool> _ensureReadyImpl({bool force = false}) async {
    // 扫描进行中禁止强制重建：重连会重置 tree，扫描中的 read 会报
    // "no share connected"。降级为非强制路径（会话尚在则直接复用）。
    if (force && _scanning) {
      Log.w('SMB', '扫描中忽略 force 重建，复用现有会话');
      force = false;
    }
    if (force) {
      _connected = false;
      _mountedShare = null;
    }
    if (!_connected) {
      final prefs = PreferencesService.instance;
      final host = prefs.nasHost;
      if (host == null || host.isEmpty) {
        Log.e('SMB', 'ensureReady 失败：未配置 NAS host');
        return false;
      }
      final ok = await _connectImpl(
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

  /// app 从后台恢复时调用：主动销毁重建会话，绕开 smb2 crate
  /// 30s 响应超时的「死连接惩罚」。
  ///
  /// iOS/Android 后台挂起会掐掉 SMB socket，但 Rust 全局会话无感知
  /// （乐观缓存 _connected 仍为 true），下次 IO 会在这条假活连接上
  /// 白等 RESPONSE_TIMEOUT=30s 才宣判 ServerUnresponsive。与其等踩坑，
  /// 不如恢复瞬间主动 force 重建——connect/协商/认证本地局域网内
  /// 几十 ms 即可完成。后台停留过短（<30s）时连接大概率仍健康，跳过。
  static Future<void> recoverAfterBackground(Duration gap) async {
    if (gap < const Duration(seconds: 30)) return;
    if (!_connected) return;
    Log.i('SMB', '后台停留 ${gap.inSeconds}s，主动重建会话');
    await ensureReady(force: true);
  }

  static Future<void> disconnect() => _inGate(() async {
    // 扫描进行中：保持会话，避免打断扫描
    if (_scanning) return;
    try {
      await smb.smbDisconnect();
    } catch (e) {
      Log.e('SMB', 'disconnect failed: $e');
    }
    stopKeepalive();
    _connected = false;
    _mountedShare = null;
    _sessionGen++;
  });

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
        } else if (_isAudio(entry.name) || _isStrm(entry.name)) {
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

  /// 是否为 STRM 指针文件（文本内容指向真实媒体位置，播放时解析）。
  static bool _isStrm(String name) {
    return name.split('.').last.toLowerCase() == 'strm';
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

    // STRM 指针文件：按歌建索引（标题取 strm 文件名），不下载不读元数据
    // （strm 是文本无音频标签）。Resolver 落地：读内容解析目标（失败不阻断
    // 索引，播放时兑底再解析）；#EXTINF 标题/时长顺带回填。
    if (_isStrm(name)) {
      StrmTarget? target;
      try {
        final text = await readRemoteText(smbPath);
        if (text != null) {
          target =
              parseStrmContent(text, fromWebdav: false, strmPath: smbPath);
        }
      } catch (e) {
        Log.w('SMB', 'STRM 解析失败 ($smbPath): $e');
      }
      final song = Song(
        id: 'smb_${smbPath.hashCode}',
        title: parsed.title,
        artist: parsed.artist ?? artistPlaceholder,
        album: albumPlaceholder,
        duration: Duration.zero,
        dominantColor: AppTheme.s2,
        strmPath: smbPath,
        strmFromWebdav: false,
        targetUri: target?.path,
        targetKind: target?.kind,
        durationEstimated: true,
      );
      // #EXTINF 标题/时长回填（Kodi 风格 strm 库的展示名）
      if (target != null) applyExtInfToSong(song, target);
      return song;
    }

    // 关闭离线缓存 → 仅索引，不占本地空间。播放时经 downloadToLocal 拉取。
    if (!PreferencesService.instance.smbOfflineCache) {
      return Song(
        id: 'smb_${smbPath.hashCode}',
        title: parsed.title,
        artist: parsed.artist ?? artistPlaceholder,
        album: albumPlaceholder,
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
      String artist = artistPlaceholder;
      String album = albumPlaceholder;
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

  /// 读 SMB 远端文件头部提取内嵌封面，并一并回填真实元数据
  ///（album/artist/时长：离线缓存关模式扫描时是占位值）。
  /// 返回是否有进展（新拿到封面或回填了元数据），供上层统计。
  /// 成功设置 song.coverUrl/hasCover；失败静默（封面保持纯色占位）。
  /// 会话可能已断开（服务器空闲超时、iOS 后台回收等）：
  /// 首次尝试前先自愈就绪，失败后按会话代数判定是否需要重连再试。
  static Future<bool> fetchRemoteCover(Song song) async {
    // STRM 歌的 smbPath 为空，用 Resolver 落地的目标地址
    final smbPath = song.smbPath ?? (song.isStrm ? song.targetUri : null);
    if (smbPath == null || smbPath.isEmpty) return false;
    // 封面与元数据都已就绪的不重复处理
    if (song.coverUrl != null && !needsMetadata(song)) return false;
    // 熔断冷却：死会话上连续失败后暂停封面提取，避免批间无冷却
    // 反复刷 10s 超时（历史日志：连续 4 轮封面批每轮全挂，期间
    // 播放/下载被连接竞争拖垮，点歌 34s 才出声）。
    if (DateTime.now().isBefore(_coverCooldownUntil)) return false;
    // 播放/下载让路：后台封面提取不与前台播放竞争 NAS 连接数。
    if (playbackActive) return false;
    // 会话熔断：连续封面失败超过阈值，判定会话不健康，直接走重建而非逐条 10s 白等。
    // 避免死会话上批量封面提取每条都挂满超时再重试的雪崩（实测 6~8 条连刷）。
    if (_coverFailStreak >= _coverFailThreshold) {
      Log.w('SMB', '封面提取熔断：连续失败 $_coverFailStreak 次，主动重建会话');
      await ensureReady(force: true);
      _coverFailStreak = 0;
      if (song.coverUrl != null && !needsMetadata(song)) return false;
      if (!await ensureReady()) return false;
    } else {
      if (!await ensureReady()) return false;
    }
    final hadCover = song.coverUrl != null;
    final neededMeta = needsMetadata(song);
    final gen = _sessionGen;
    try {
      await _fetchRemoteCoverOnce(song, smbPath);
      _coverFailStreak = 0;
    } catch (e) {
      _coverFailStreak++;
      Log.w('SMB', '远端封面提取失败 ($smbPath): $e，会话重建后重试 (连续失败 $_coverFailStreak)');
      if (_coverFailStreak >= _coverFailThreshold) {
        Log.w('SMB', '封面提取达到熔断阈值，本批剩余封面跳过');
        // 冷却 60s：让死会话自愈/重建期间不再反复踩雷
        _coverCooldownUntil =
            DateTime.now().add(const Duration(seconds: 60));
        return false;
      }
      if (!await _retryReady(gen)) {
        Log.e('SMB', '封面重试中止：会话不可用');
        return false;
      }
      try {
        await _fetchRemoteCoverOnce(song, smbPath);
        _coverFailStreak = 0;
      } catch (e2) {
        _coverFailStreak++;
        Log.e('SMB', '远端封面提取重试仍失败 ($smbPath): $e2');
      }
    }
    final gotCover = !hadCover && song.coverUrl != null;
    final gotMeta = neededMeta && !needsMetadata(song);
    return gotCover || gotMeta;
  }

  /// 元数据占位回填：仅覆盖仍为占位值的字段（album/artist/估算时长），
  /// 已有真实值不动。返回是否有字段被回填。
  static bool _backfillMetadata(Song song, MetadataResult meta) {
    var changed = false;
    final album = meta.album;
    if (song.album == albumPlaceholder && album != null && album.isNotEmpty) {
      song.album = album;
      changed = true;
    }
    final artist = meta.artist;
    if (song.artist == artistPlaceholder && artist != null && artist.isNotEmpty) {
      song.artist = artist;
      changed = true;
    }
    if (song.durationEstimated && meta.durationSecs > 0) {
      song.duration =
          Duration(milliseconds: (meta.durationSecs * 1000).round());
      song.durationEstimated = false;
      changed = true;
    }
    if (changed) {
      Log.v('SMB', '元数据回填 (${song.title}): album=${song.album}, artist=${song.artist}');
    }
    return changed;
  }

  /// 操作失败后的会话重建：发起时记录的代数为 [gen]，若期间已被
  /// 其他任务重建过（代数变化）则直接复用新会话，否则强制重建。
  /// 避免并发失败任务各自 force 重连互相摧毁刚建好的会话。
  static Future<bool> _retryReady(int gen) async {
    if (_sessionGen != gen) return _connected && _mountedShare != null;
    return ensureReady(force: true);
  }

  /// 从 NAS 远端读取与音频同目录同名的歌词文件（.lrc/.LRC），
  /// 失败（文件不存在/会话断）返回 null。歌词是小文本，直接读全文。
  static Future<String?> fetchRemoteLyrics(String smbPath) async {
    if (!_connected) return null;
    final base = smbPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
    for (final ext in const ['.lrc', '.LRC']) {
      try {
        final bytes = await smb.smbReadFile(path: '$base$ext');
        if (bytes.isEmpty) continue;
        return decodeLrcBytes(bytes);
      } catch (_) {
        // 文件不存在或读取失败，尝试下一个扩展名
        continue;
      }
    }
    return null;
  }

  /// 读取远端文本文件内容（STRM 指针解析用），失败/为空返回 null。
  static Future<String?> readRemoteText(String smbPath) async {
    try {
      final bytes = await smb.smbReadFile(path: smbPath);
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      Log.w('SMB', 'readRemoteText failed ($smbPath): $e');
      return null;
    }
  }

  static Future<void> _fetchRemoteCoverOnce(Song song, String smbPath) async {
    // 1MB：FLAC 前置 metadata 块/大尺寸 ID3v2 内嵌封面可能超 512KB，
    // 截断后标签解析失败导致封面静默丢失
    final head = await smb.smbReadHead(
      path: smbPath,
      maxLen: BigInt.from(1024 * 1024),
    );
    if (head.isEmpty) {
      Log.w('SMB', '封面提取：头部为空 ($smbPath)');
      return;
    }
    // 头部解析出封面则完成；否则读尾部兜底：M4A/AAC/ALAC 的 moov
    // 元数据块（含内嵌封面 covr）常在文件末尾，头部读不到封面。
    if (!await _extractCoverFromBytes(song, smbPath, head)) {
      try {
        final tail = await smb.smbReadTail(
          path: smbPath,
          maxLen: BigInt.from(1024 * 1024),
        );
        if (tail.isEmpty) {
          Log.v('SMB', '封面提取：头部无封面且尾部为空 ($smbPath, head=${head.length}B)');
          return;
        }
        if (!await _extractCoverFromBytes(song, smbPath, tail)) {
          // 打点：头尾都读到数据但均无封面（真无封面 / 封面超出
          // 1MB 读取窗口 / 标签布局特殊）。用户反馈"文件都有封面却
          // 解析不出"时，此日志用于定位具体文件与原因。
          Log.v(
            'SMB',
            '封面提取：头/尾均无封面标签 ($smbPath, head=${head.length}B, '
            'tail=${tail.length}B)',
          );
          // 仅当元数据仍未从片段回填（如 M4A，moov 在尾部无法从 head/tail
          // 片段解析）才整文件下载兜底。FLAC/MP3/OGG 的封面与元数据都在
          // 头部，head 已回填元数据，此时再整文件下载纯属浪费（启动批量
          // 提取会灌入数百 MB 流量、徒增 SMB 操作触发偶发 NOT_A_DIRECTORY）。
          if (needsMetadata(song)) {
            await _fetchCoverByFullDownload(song, smbPath);
          } else {
            Log.v('SMB', '封面提取：头/尾均无封面（元数据已回填，跳过整文件兜底）($smbPath)');
          }
        }
      } catch (e) {
        // 尾部读取失败（会话断/格式不支持）：头部已失败过，静默跳过
        Log.v('SMB', '封面尾部兜底失败 ($smbPath): $e');
      }
    }
  }

  /// 兜底：整文件下载后解析封面。仅限小文件（≤30MB），
  /// 覆盖 ID3v2 标签超出 1MB 头/尾读取窗口被截断的场景。
  /// 下载复用播放缓存（downloadToLocal），小文件局域网秒级完成。
  static Future<void> _fetchCoverByFullDownload(
    Song song,
    String smbPath,
  ) async {
    try {
      final size = await smb.smbFileSize(path: smbPath);
      if (size > BigInt.from(30 * 1024 * 1024)) {
        Log.v('SMB', '封面整文件兜底跳过（文件过大 ${size}B）: $smbPath');
        return;
      }
      final localPath = await downloadToLocal(smbPath);
      if (localPath == null) {
        Log.v('SMB', '封面整文件兜底下载失败: $smbPath');
        return;
      }
      final meta = await rs.readMetadata(localPath);
      // 与读头路径一致：顺手回填占位元数据（无封面也生效）
      _backfillMetadata(song, meta);
      if (meta.hasCover && meta.coverBytes.isNotEmpty) {
        final appDir = await getApplicationDocumentsDirectory();
        final coversDir = Directory('${appDir.path}/.covers');
        if (!await coversDir.exists()) {
          await coversDir.create(recursive: true);
        }
        final coverFile =
            File('${coversDir.path}/smb_${smbPath.hashCode}.jpg');
        await coverFile.writeAsBytes(meta.coverBytes);
        song.coverUrl = coverFile.path;
        song.hasCover = true;
        Log.v('SMB', '封面整文件兜底成功: $smbPath');
      } else {
        Log.v('SMB', '封面整文件兜底仍无封面: $smbPath');
      }
    } catch (e) {
      Log.v('SMB', '封面整文件兜底失败: $smbPath: $e');
    }
  }

  /// 从远端读到的字节解析内嵌封面：写带真实扩展名的临时文件（lofty 按
  /// 扩展名探测格式），成功后写 .covers 缓存。返回是否解析到封面。
  static Future<bool> _extractCoverFromBytes(
    Song song,
    String smbPath,
    List<int> bytes,
  ) async {
    final appDir = await getApplicationDocumentsDirectory();
    final headDir = Directory('${appDir.path}/.smb_head');
    if (!await headDir.exists()) await headDir.create(recursive: true);
    // 必须保留真实音频扩展名：lofty/symphonia 按扩展名探测格式，
    // 未知后缀会直接探测失败，封面静默丢失（历史 bug：用 .head）
    final ext = smbPath.split('.').last.toLowerCase();
    final headFile = File('${headDir.path}/${smbPath.hashCode}.$ext');
    await headFile.writeAsBytes(bytes);
    try {
      final meta = await rs.readMetadata(headFile.path);
      // 元数据回填：解析出的 album/artist/时长此前只用来提封面就被丢弃，
      // 现在顺手覆盖占位值（幂等：已有真实值不动），无封面也生效。
      _backfillMetadata(song, meta);
      if (meta.hasCover && meta.coverBytes.isNotEmpty && song.coverUrl == null) {
        final coversDir = Directory('${appDir.path}/.covers');
        if (!await coversDir.exists()) await coversDir.create(recursive: true);
        final coverFile =
            File('${coversDir.path}/smb_${smbPath.hashCode}.jpg');
        await coverFile.writeAsBytes(meta.coverBytes);
        song.coverUrl = coverFile.path;
        song.hasCover = true;
        return true;
      }
    } catch (e) {
      // 截断数据/格式不支持：解析失败不致命，交由兜底或保持占位色
      Log.v('SMB', '封面字节解析失败 ($smbPath): $e');
    } finally {
      // 头部临时文件用完即删
      if (await headFile.exists()) await headFile.delete();
    }
    return false;
  }

  /// 播放时按需下载单曲到本地缓存，返回可播放的本地路径（已存在则直接复用）。
  /// 用于离线缓存关闭时按需拉取；缓存复用避免重复下载。
  /// 同一 smbPath 的并发调用去重：共享同一次下载，避免 .part 写入竞态。
  static Future<String?> downloadToLocal(String smbPath) async {
    if (smbPath.isEmpty) return null;
    // 防御：历史歌单脏数据可能混入 .lrc 歌词条目（旧版本扫描把歌词
    // 当音频收录），直接拒绝下载，避免预取/播放把歌词文件拉进缓存
    // 当音频播放（解码报 "no suitable format reader"）。
    final ext = smbPath.split('.').last.toLowerCase();
    if (!ImportService.extensions.contains(ext)) {
      Log.w('SMB', 'downloadToLocal 拒绝非音频路径 ($smbPath)');
      return null;
    }
    enterPlayback();
    try {
      final pending = _downloading[smbPath];
      if (pending != null) return await pending;
      final fut = _downloadToLocalImpl(smbPath);
      _downloading[smbPath] = fut;
      try {
        return await fut;
      } finally {
        _downloading.remove(smbPath);
      }
    } finally {
      exitPlayback();
    }
  }

  static Future<String?> _downloadToLocalImpl(String smbPath) async {
    if (smbPath.isEmpty) return null;
    // 缓存命中短路：本地缓存已存在即直接返回，不碰 SMB 会话。
    // 原实现在 ensureReady + 探活（可能触发局域网往返/锁等待）之后
    // 才查缓存，缓存命中场景白耗 2~3s（实测 2842ms）。
    final cached = await cachedLocalPath(smbPath);
    if (cached != null) return cached;
    // 自愈：会话丢失（测试连接断开/重启等）时自动重连并挂载共享
    if (!await ensureReady()) {
      Log.e('SMB', 'downloadToLocal 中止：会话不可用 (lastError=$lastError)');
      return null;
    }
    // 播放前探活：死连接上首块读会白挂超时（open 10s + 分块 30s），
    // 先探活发现死连接立即 force 重建，把等待消化在 IO 之前
    if (!await ensureHealthy()) {
      Log.e('SMB', 'downloadToLocal 探活失败：会话不可用');
      return null;
    }
    final gen = _sessionGen;
    var path = await _doDownload(smbPath);
    if (path == null) {
      // 下载失败：连接可能已失效（尤其 iOS 后台回收后，缓存的 _mountedShare
      // 会误判为就绪）。按代数判定重建后重试一次。
      Log.w('SMB', '首次下载失败，会话重建后重试 ($smbPath)');
      if (await _retryReady(gen)) {
        path = await _doDownload(smbPath);
      }
    }
    return path;
  }

  /// 计算单曲本地缓存路径；已存在且非空则返回，否则返回 null。
  static Future<String?> cachedLocalPath(String smbPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.smb_cache');
      if (!await cacheDir.exists()) return null;
      final name = smbPath.split('/').last;
      final localFile = File('${cacheDir.path}/${smbPath.hashCode}_$name');
      if (await localFile.exists() && await localFile.length() > 0) {
        return localFile.path;
      }
      return null;
    } catch (e) {
      Log.e('SMB', '缓存路径检查失败: $e');
      return null;
    }
  }

  /// 计算单曲缓存目标完整路径（与 [cachedLocalPath] 命名一致）；
  /// 边下边播时把该路径传给 enginePlaySmbStream 作 cacheFinalPath，
  /// 流读完 rename 成正式缓存后，下次播放直接命中。
  static Future<String?> cacheTargetFor(String smbPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.smb_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final name = smbPath.split('/').last;
      return '${cacheDir.path}/${smbPath.hashCode}_$name';
    } catch (e) {
      Log.e('SMB', '缓存目标路径计算失败: $e');
      return null;
    }
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
