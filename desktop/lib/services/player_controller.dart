import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../models/playlist.dart';
import '../src/rust/api/analyze.dart' as frb_analyze;
import 'analysis_service.dart';
import 'engine.dart';
import 'library.dart';
import 'lyrics.dart';
import 'nas_service.dart';
import 'subsonic_service.dart';
import 'webdav_service.dart';
import 'strm_resolver.dart';
import 'stable_hash.dart';
import 'cover_cache.dart';
import 'track_repository.dart';
import 'cache_cleaner.dart';
import 'playback_state.dart';
import 'network_source_config.dart';

/// Playback loop behaviour.
enum RepeatMode { off, all, one }

/// Central playback engine + library state.
///
/// 音频后端为 Rust `Engine`（经 FFI 桥接 `audio_core`），继承 hi-res / DSP /
/// bit-perfect 能力。播放顺序（队列 / 随机 / 循环）由本控制器在 Dart 侧管理，
/// 每首曲目通过 `engine.play(path)` 下发给引擎；曲目自然结束时由引擎的
/// `stopped` 事件驱动 `next()` 切歌（gapless / 引擎队列为 Phase 2）。
///
/// 收藏 / 播放列表 / 音量 / 模式经 shared_preferences 持久化；全部 UI 状态
/// 通过统一广播流暴露。
class PlayerController {
  Engine? _engine;
  String? _engineInitError;
  /// 暴露引擎实例给设置页等 UI 直接调用 DSP / 输出配置命令。
  Engine? get engine => _engine;

  /// 引擎是否可播放（动态库已加载且初始化成功）。
  bool get engineReady => _engine != null && _engineInitError == null;

  /// 引擎初始化错误信息（null 表示成功或尚未加载）。
  String? get engineInitError => _engineInitError;

  /// prefs 实例缓存：init 时加载一次，之后所有持久化走缓存引用。
  /// 为 null（如单元测试未调 init）时持久化静默跳过，不影响内存状态。
  SharedPreferences? _prefs;

  /// 用户添加过的音乐文件夹（持久化，重启后重扫恢复曲库）。
  List<String> _folders = const [];

  List<Track> _library = const [];
  List<Track> _queue = const [];
  List<Track> _queueBase = const [];
  int? _queueIndex;

  final Set<String> _favoriteIds = {};
  List<Playlist> _playlists = const [];

  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;
  double _volume = 1.0;

  // —— 播放续播恢复（重启后接着播）——
  String? _loadedTrackId; // 已加载到引擎的 track id；区分 resume 是「已暂停」还是「从未播放（启动恢复）」
  Duration? _pendingSeek; // 启动恢复时待应用的进度，首次 resume 播放时消费
  DateTime? _lastPersistAt; // 进度落盘节流时间戳

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 用户主动停止标记：区分「自然结束」与「手动停止」，避免误触发切歌
  bool _stopRequested = false;

  /// 当前曲目是否为「流式边下边播」（NAS/WebDAV）。流式源不可 seek，
  /// seek 需重启流（见 [_restartStreamSeek]）；本地/下载回退则走引擎 seek。
  bool _streaming = false;

  /// 最近一次流式 seek（下载后切换本地播放）的时刻：切换会拆掉旧流，
  /// 若引擎因旧流被拆卸而发 stopped（core 已修 gen 竞态，此处双保险），
  /// 窗口内收到的 stopped 视为预期、不切歌；窗口外仍是正常自然结束语义。
  DateTime? _lastStreamSeekAt;

  /// 流式播放中发起 seek 的等待目标（下载期间可能被覆盖为最新值）
  Duration? _pendingStreamSeek;

  /// 流式 seek 下载/切换是否进行中（防重入，单飞）
  bool _streamSeekPending = false;

  final _positionSC = StreamController<Duration>.broadcast();
  final _durationSC = StreamController<Duration>.broadcast();
  final _playingSC = StreamController<bool>.broadcast();
  final _indexSC = StreamController<int?>.broadcast();
  final _lyricsSC = StreamController<List<LyricLine>>.broadcast();
  final _favoritesSC = StreamController<void>.broadcast();
  final _playlistsSC = StreamController<void>.broadcast();
  final _modeSC = StreamController<void>.broadcast();
  final _librarySC = StreamController<void>.broadcast();
  /// 音频分析完成（广播 trackId）：播放页据此刷新 BPM/Key 徽章。
  final _analysisSC = StreamController<String>.broadcast();

  /// 实时频谱（16 频段 0~1，引擎 ~25Hz 推送）：可视化组件订阅。
  /// 暂停/停止后引擎不再推送，UI 侧自行衰减到零（见 SpectrumVisualizer）。
  final _spectrumSC = StreamController<List<double>>.broadcast();

  /// 用户可读错误（曲库写入失败等）。UI 订阅后以 SnackBar 呈现；
  /// 详细异常走 debugPrint（仅 debug 构建），对用户只暴露一句人话。
  final _errorSC = StreamController<String>.broadcast();

  Stream<Duration> get positionStream => _positionSC.stream;
  Stream<Duration> get durationStream => _durationSC.stream;
  Stream<bool> get playingStream => _playingSC.stream;
  Stream<int?> get indexStream => _indexSC.stream;
  Stream<List<LyricLine>> get lyricsStream => _lyricsSC.stream;
  Stream<void> get favoritesStream => _favoritesSC.stream;
  Stream<void> get playlistsStream => _playlistsSC.stream;
  Stream<void> get modeStream => _modeSC.stream;
  Stream<String> get analysisStream => _analysisSC.stream;

  /// 实时频谱事件流（16 频段幅值 0~1）。
  Stream<List<double>> get spectrumStream => _spectrumSC.stream;

  /// 曲库内容变化（添加文件夹 / 启动重扫完成）。UI 订阅以替代 setState 刷新。
  Stream<void> get libraryStream => _librarySC.stream;

  /// 用户可读错误事件（持久化失败等），UI 订阅后弹提示。
  Stream<String> get errorStream => _errorSC.stream;

  /// 统一错误上报：debugPrint 记录完整异常（诊断用），errorStream 只发
  /// 一句用户能看懂的话（呈现用）。持久化/导入失败不得静默。
  void _reportError(String message, Object e) {
    debugPrint('PlayerController: $message ($e)');
    if (!_errorSC.isClosed) _errorSC.add(message);
  }

  List<Track> get library => _library;
  List<Playlist> get playlists => _playlists;
  Set<String> get favoriteIds => _favoriteIds;
  List<String> get folders => _folders;

  /// 当前播放队列（shuffle 开启时为打乱顺序）。
  List<Track> get queue => _queue;

  /// 基准队列（未打乱的原始顺序，shuffle 关闭时与 [queue] 相同）。
  List<Track> get queueBase => _queueBase;
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffle => _shuffle;
  double get volume => _volume;

  Track? get currentTrack =>
      (_queueIndex == null || _queue.isEmpty) ? null : _queue[_queueIndex!];
  int? get currentIndex => _queueIndex;
  bool get isPlaying => _playing;
  Duration get position => _position;
  Duration get duration => _duration;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _favoriteIds.addAll(_prefs!.getStringList('favorites') ?? []);
      final plJson = _prefs!.getStringList('playlists') ?? [];
      _playlists = plJson
          .map((e) => Playlist.fromJson(jsonDecode(e) as Map<String, dynamic>))
          .toList();
      _volume = (_prefs!.getDouble('volume') ?? 1.0).clamp(0.0, 1.0);
      final rm = _prefs!.getString('repeatMode');
      _repeatMode = RepeatMode.values.firstWhere(
        (e) => e.name == rm,
        orElse: () => RepeatMode.off,
      );
      _shuffle = _prefs!.getBool('shuffle') ?? false;
      _folders = _prefs!.getStringList('libraryFolders') ?? [];
    } catch (e) {
      debugPrint('prefs load error: $e');
    }

    // 恢复 Subsonic 会话凭据（WebDAV/NAS 凭据由 NetworkSourceConfig 直接读）。
    try {
      SubsonicService.loadFromPrefs();
    } catch (e) {
      debugPrint('subsonic prefs load error: $e');
    }

    // 加载 Rust 引擎（找不到 dylib 时为 null，播放不可用但 App 仍可启动）
    _engine = await Engine.load();
    _engineInitError = _engine == null
        ? null
        : await _engine!.initialize(
            sampleRate: 44100,
            channels: 2,
            bufferMs: 280,
            // 高级音频引擎配置从设置页持久化（reinitialize 会保留这些值）
            bitPerfect: _prefs!.getBool('engine.bitPerfect') ?? false,
            autoSampleRate: _prefs!.getBool('engine.autoSampleRate') ?? false,
            crossfadeMs: (_prefs!.getInt('engine.crossfadeMs') ?? 0)
                .clamp(0, 8000),
          );
    if (_engineInitError != null) {
      debugPrint('engine init error: $_engineInitError');
    }
    _engine?.events.listen(_onEngineEvent);
    await _engine?.setVolume(_volume);
    // 恢复音频输出/DSP 设置（设备、采样率、效果链、EQ、FIR），
    // 与设置页同源读写 SharedPreferences。
    await _restoreAudioSettings();

    // 恢复曲库：网络音源靠 SQLite 跨重启存活（直接读回）；本地文件夹保持
    // 每次启动重扫（与现状一致，且首次运行也会把本地曲库写入 DB）。
    final swDb = Stopwatch()..start();
    await TrackRepository.init();
    try {
      final dbTracks = await TrackRepository.getAll();
      if (dbTracks.isNotEmpty) {
        addLibraryFiles(dbTracks);
        debugPrint(
            '[perf] DB 曲库恢复 ${dbTracks.length} 首: ${swDb.elapsedMilliseconds}ms');
        // DB 恢复后立即广播：UI 提前显示曲库与封面（此前要等全部文件夹
        // 扫完才广播一次，大曲库开场长时间空白，列表“显得慢”）。
        _librarySC.add(null);
        // 补提网络源封面：封面文件可能在缓存清理/历史操作中丢失，
        // 后台快速路径（已缓存直接写回）+ 缺失才远程提取，不阻塞启动。
        final remote =
            dbTracks.where((t) => t.source != TrackSource.local).toList();
        if (remote.isNotEmpty) extractCoversFor(remote);
      }
    } catch (e) {
      _reportError('曲库读取失败，本次启动以空库运行', e);
    }
    if (_folders.isNotEmpty) {
      for (final folder in _folders) {
        final swFolder = Stopwatch()..start();
        final scanned = await scanFolder(folder);
        addLibraryFiles(scanned);
        try {
          await TrackRepository.syncScan(scanned, localPrefix: folder);
        } catch (e) {
          _reportError('曲库写入失败，扫描结果可能未保存', e);
        }
        debugPrint('[perf] 扫描 $folder: ${scanned.length} 首, '
            '${swFolder.elapsedMilliseconds}ms');
        // 每个文件夹扫完立即广播（此前等全部结束才显示一次）
        _librarySC.add(null);
        // 扫描期已直接落盘封面并回填 coverUrl（library.dart _seedCover），
        // 此处仅补漏（扫描中标签读取失败的文件），后台执行不阻塞 UI。
        extractCoversFor(scanned);
      }
    }
    // 恢复上次的播放队列/曲目/进度（曲库已在上面就绪）
    await _restorePlayback();
    // 曲库就绪后清理孤儿缓存（本地文件夹重扫 + 源差集同步均已落库）
    await _cleanOrphanCaches();
    // 首次启动时的缩略图回填：老缓存封面（升级前落盘）没有缩略图，
    // 后台限并发补齐，确保列表滚动也吃到缩略图收益（会话内仅执行一次）。
    unawaited(_backfillCoverThumbs());
  }

  /// 会话级缩略图回填：扫描曲库中已带封面但缺缩略图的曲目，限并发生成。
  /// 每张只读一次原图再编码，之后的启动全是 existsSync 快速跳过。
  /// hasSource ?? 不需要：仅处理 coverUrl 为本地缓存文件的（网络 URL 无缩略图）。
  static bool _thumbSwept = false;

  Future<void> _backfillCoverThumbs() async {
    if (_thumbSwept) return;
    _thumbSwept = true;
    final files = _library
        .map((t) => t.coverUrl)
        .whereType<String>()
        .where((u) => !u.startsWith('http://') && !u.startsWith('https://'))
        .map(File.new)
        .toList();
    if (files.isEmpty) return;
    var i = 0;
    final sw = Stopwatch()..start();
    Future<void> worker() async {
      while (i < files.length) {
        final f = files[i++];
        await CoverCache.instance.ensureThumb(f);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    debugPrint('[perf] 缩略图回填: ${files.length} 张, '
        '${sw.elapsedMilliseconds}ms');
  }

  /// 恢复音频输出与 DSP 设置（prefs 键与设置页一致）；引擎未加载则跳过。
  /// 失败仅记录，不影响启动流程（恢复是可丢失的优化，非正确性前提）。
  Future<void> _restoreAudioSettings() async {
    final p = _prefs;
    if (p == null || _engine == null) return;
    try {
      final device = p.getString('outputDevice');
      if (device != null) await _engine?.setOutputDevice(device);
      final sr = p.getInt('outputSampleRate');
      if (sr != null) await _engine?.setOutputSampleRate(sr);
      if (p.getBool('exclusiveMode') ?? false) {
        await _engine?.reinitialize(exclusiveMode: true);
      }
      await _engine?.setStereoWidener(
          p.getBool('dsp.widener') ?? false, p.getDouble('dsp.widenerWidth') ?? 0.5);
      await _engine?.setCrossfeed(p.getBool('dsp.crossfeed') ?? false);
      await _engine?.setLimiter(p.getBool('dsp.limiter') ?? false);
      await _engine?.setDither(p.getBool('dsp.dither') ?? false);
      await _engine?.setNoiseShaping(p.getBool('dsp.noiseShaping') ?? false);
      await _engine?.setReplaygainGain(p.getDouble('dsp.gain') ?? 0);
      await _engine?.setSpeed(p.getDouble('dsp.speed') ?? 1.0);
      final preset = p.getString('dsp.preset');
      if (preset != null) await _engine?.applyPreset(preset);
      final eq = p.getString('dsp.autoEq');
      if (eq != null && eq.isNotEmpty) await _engine?.setAutoEq(eq);
      final ir = p.getString('dsp.irPath');
      if (ir != null && ir.isNotEmpty) await _engine?.loadIr(ir);
    } catch (e) {
      debugPrint('restore audio settings error: $e');
    }
  }

  /// 曲库差集同步后删除已不存在曲目的缓存文件；失败仅记录，不阻塞流程。
  Future<void> _cleanOrphanCaches() async {
    try {
      await CacheCleaner.cleanOrphans(await TrackRepository.getAll());
    } catch (e) {
      debugPrint('cache cleanup skipped: $e');
    }
  }

  void _onEngineEvent(EngineEvent e) {
    switch (e.type) {
      case 'position':
        if (e.value != null) {
          _position = Duration(milliseconds: (e.value! * 1000).round());
          _positionSC.add(_position);
          _throttledPersistPosition();
        }
      case 'duration':
        if (e.value != null) {
          // 无条件接受：core 的流式时长估算已收敛后再发出（首报 5s、未收敛
          // 每 3s 修正、1% 收敛停发、EOF 回传真实时长），播放中收到的值
          // 就是要展示的值。曾加过「相对>20% 拒收」滤波，但 NAS 扫描期的
          // durationHint 是按 1000kbps 粗估（误差可数倍），估算收敛值与
          // 粗估值偏差大概率超阈值 → 真实时长被永久拒收，进度条/结束时间
          // 钉死在粗估上（用户实测「结束时间不准确」的根因）。
          _duration = Duration(milliseconds: (e.value! * 1000).round());
          _durationSC.add(_duration);
        }
      case 'stopped':
        // 流式 seek 重启流（拖进度条）时，core 的 play_stream 会先 stop_playback
        // 拆掉旧流再起新流，必然发一次 stopped（core/state.rs 的流式 seek 历史坑）。
        // 这个伪事件不能翻转 _playing —— 新流的状态才是权威，否则 UI 误显"暂停"
        // 且播放按钮 resume 对已播/已停引擎无效（"拖一下就停、点了没反应"）。
        if (_lastStreamSeekAt != null &&
            DateTime.now().difference(_lastStreamSeekAt!) <
                const Duration(seconds: 3)) {
          debugPrint('[stopped] 流式 seek 重启伪停止，忽略(不翻转播放态)');
          return;
        }
        _playing = false;
        _playingSC.add(false);
        if (_stopRequested) {
          _stopRequested = false;
        } else {
          // 自然结束 → 切下一首（遵循循环/随机模式）
          next();
        }
      case 'error':
        debugPrint('engine error: ${e.message}');
      case 'spectrum':
        final bands = e.bands;
        if (bands != null && !_spectrumSC.isClosed) _spectrumSC.add(bands);
      default:
        break;
    }
  }

  void setLibrary(List<Track> list) {
    _library = list;
    _queueBase = list;
    _queue = _shuffle ? _shuffled(list, null) : list;
    _queueIndex = null;
  }

  /// 向曲库累积添加一批曲目（按 id 去重）。
  /// 尚未开始播放时同步重建队列；正在播放时只更新曲库，不打断当前曲目。
  void addLibraryFiles(List<Track> tracks) {
    final map = <String, Track>{};
    for (final t in _library) {
      map[t.id] = t;
    }
    for (final t in tracks) {
      // 扫描重建的 Track 实例常不带封面（引擎未加载/标签读取失败时）；
      // 库里（含 DB 恢复）的旧实例可能已有 coverUrl：保留旧值，避免每次
      // 启动扫描后封面被清掉、再等提取管线重新关联（灰阶闪现的元凶之一）。
      final old = map[t.id];
      if (old != null && t.coverUrl == null && old.coverUrl != null) {
        map[t.id] = t.copyWith(coverUrl: old.coverUrl);
      } else {
        map[t.id] = t;
      }
    }
    _library = map.values.toList();
    _queueBase = _library;
    if (_queueIndex == null) {
      _queue = _shuffle ? _shuffled(_library, null) : _library;
    }
  }

  /// 添加一个音乐文件夹：持久化路径 + 扫描并入曲库 + 写库，并广播 libraryStream。
  /// 重复添加同一文件夹允许（等价于手动重扫，按路径前缀整段替换，覆盖增删）。
  Future<void> addFolder(String path) async {
    if (!_folders.contains(path)) {
      _folders = [..._folders, path];
      await _prefs?.setStringList('libraryFolders', _folders);
    }
    final tracks = await scanFolder(path);
    addLibraryFiles(tracks);
    try {
      await TrackRepository.syncScan(tracks, localPrefix: path);
    } catch (e) {
      _reportError('曲库保存失败，本次扫描结果未持久化', e);
    }
    _librarySC.add(null);
    // 后台提取本地封面（不阻塞 UI）
    extractCoversFor(tracks);
  }

  /// 移除一个音乐文件夹（曲库与 DB 中该文件夹下的曲目一并移除）。
  Future<void> removeFolder(String path) async {
    _folders = _folders.where((f) => f != path).toList();
    await _prefs?.setStringList('libraryFolders', _folders);
    _library = _library
        .where((t) => !(t.filePath ?? '').startsWith('$path/'))
        .toList();
    _queueBase = _library;
    if (_queueIndex == null) {
      _queue = _shuffle ? _shuffled(_library, null) : _library;
    }
    try {
      await TrackRepository.deleteLocalUnder(path);
    } catch (e) {
      _reportError('移除文件夹失败，曲库可能残留该目录曲目', e);
    }
    _librarySC.add(null);
  }

  /// 彻底清空所有应用内数据（**只删应用沙盒里的扫描配置与缓存副本，
  /// 不碰用户 NAS / 电脑上的真实音乐文件**）：
  /// 内存曲库 + 队列、本地文件夹配置、NAS/WebDAV/Subsonic 连接配置、
  /// 收藏、播放列表、循环/随机设置、磁盘缓存目录（.covers/.nas_cache/.webdav_cache）。
  /// 音量偏好保留。
  Future<void> clearAllData() async {
    // 1. 停止播放并重置播放状态
    try {
      await _engine?.stop();
    } catch (_) {
      // 引擎可能未初始化，忽略
    }
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;

    // 2. 清空内存曲库与队列
    setLibrary([]);

    // 2.5 清空持久化曲库（SQLite 整表删除；只删索引，不碰真实音乐文件）
    try {
      await TrackRepository.clear();
    } catch (e) {
      _reportError('清空曲库失败，重启后旧曲库可能恢复', e);
    }

    // 3. 清空本地文件夹配置（决定启动重扫）
    _folders = const [];
    await _prefs?.remove('libraryFolders');

    // 4. 清空三类网络音源连接配置
    await NetworkSourceConfig.instance.clearNasConfig();
    await NetworkSourceConfig.instance.clearWebdavConfig();
    await NetworkSourceConfig.instance.clearSubsonicConfig();
    SubsonicService.clear();

    // 5. 清空收藏与播放列表
    _favoriteIds.clear();
    await _prefs?.remove('favorites');
    _playlists = const [];
    await _prefs?.remove('playlists');

    // 6. 重置播放模式（loop/shuffle），音量保留
    _shuffle = false;
    await _prefs?.remove('shuffle');
    _repeatMode = RepeatMode.off;
    await _prefs?.remove('repeatMode');

    // 6.5 清空续播状态
    _loadedTrackId = null;
    _pendingSeek = null;
    _lastPersistAt = null;
    _queueIndex = null;
    _queue = const [];
    _queueBase = const [];
    if (_prefs != null) await PlaybackSnapshot.clear(_prefs!);

    // 6.7 清空音频输出与 DSP 设置（设备/采样率/效果链/EQ/FIR）
    for (final k in const [
      'outputDevice', 'outputSampleRate', 'exclusiveMode',
      'engine.bitPerfect', 'engine.autoSampleRate', 'engine.crossfadeMs',
      'dsp.widener', 'dsp.widenerWidth', 'dsp.crossfeed', 'dsp.limiter',
      'dsp.dither', 'dsp.noiseShaping', 'dsp.gain', 'dsp.speed',
      'dsp.preset', 'dsp.autoEq', 'dsp.irPath',
    ]) {
      await _prefs?.remove(k);
    }

    // 7. 删除磁盘缓存目录（仅副本，安全）
    await _clearCacheDirs();

    // 广播播放状态变化：clearAllData 已重置 _playing/_position/_duration/
    // _queueIndex，必须同步 emit 对应流，否则传输栏仍显示旧曲在播放、进度条
    // 停在旧位置、且 currentTrack 不刷新（点播放变 no-op，只能重启恢复）。
    _playingSC.add(_playing);
    _positionSC.add(_position);
    _durationSC.add(_duration);
    _indexSC.add(_queueIndex);

    // 广播曲库变化，UI 刷新为空库
    _librarySC.add(null);
  }

  /// 删除应用 Documents 下的三个缓存目录（封面 / NAS 边下边播 / WebDAV 边下边播）。
  /// 均为音轨副本或生成物，不含用户源文件。
  Future<void> _clearCacheDirs() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      for (final name in const [
        '.covers',
        '.nas_cache',
        '.webdav_cache',
        '.subsonic_cache',
      ]) {
        final dir = Directory(p.join(appDir.path, name));
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint('clear cache dirs error: $e');
    }
  }

  /// Resolve a playlist's ids into actual [Track] objects from the library.
  List<Track> tracksOfPlaylist(Playlist pl) =>
      _library.where((t) => pl.trackIds.contains(t.id)).toList();

  // ---- 封面提取（本地文件）----

  /// 会话内已确认无内嵌封面的本地曲目（提取失败过）：
  /// 扫描期已读过一次元数据确认无封面，再重复提取纯浪费 FFI + IO。
  final Set<String> _coverMissing = {};

  /// 为本地/NAS 曲目批量提取封面（后台、限并发）。已缓存或已带 coverUrl 的跳过。
  /// 不阻塞调用方；提取成功写回 [Track.coverUrl] 并广播 libraryStream 增量刷新。
  void extractCoversFor(List<Track> tracks) {
    final pending = tracks.where((t) {
      if (t.source == TrackSource.subsonic) {
        // Subsonic 封面是远程 URL（含会过期的鉴权 token），必须下载到本地缓存，
        // 否则数小时后 token 失效 → 封面 401。故即使已有 coverUrl 也要走提取
        // （下载后 _applyCoverUrl 会把 coverUrl 换成本地路径）。仅配置了才取。
        return SubsonicService.isConfigured;
      }
      return (t.source == TrackSource.local ||
              t.source == TrackSource.nas ||
              t.source == TrackSource.webdav) &&
          t.coverUrl == null &&
          !_coverMissing.contains(t.id);
    }).toList();
    if (pending.isEmpty) return;
    unawaited(_runCoverExtraction(pending));
  }

  Future<void> _runCoverExtraction(List<Track> pending) async {
    final cache = CoverCache.instance;
    // 快速路径：已有缓存文件的直接写回，不占并发槽
    // 注意：不能在遍历 pending 时向 pending 追加元素（会 ConcurrentModificationError），
    // 未缓存项收集到独立 todo 列表。
    final todo = <Track>[];
    for (final t in pending) {
      final cached = await cache.cachedPathFor(t);
      if (cached != null) {
        _applyCoverUrl(t, cached);
      } else {
        todo.add(t);
      }
    }
    if (todo.isEmpty) {
      _librarySC.add(null);
      return;
    }
    var i = 0;
    Future<void> worker() async {
      while (i < todo.length) {
        final t = todo[i++];
        final path = switch (t.source) {
          TrackSource.nas => await cache.extractNas(t),
          TrackSource.webdav => await cache.extractWebdav(t),
          TrackSource.subsonic => await cache.extractSubsonic(t),
          _ => await cache.extractLocal(t),
        };
        if (path != null) {
          _applyCoverUrl(t, path);
        } else if (t.source == TrackSource.local) {
          // 会话级负缓存：确认无封面后本会话不再重复提取。
          _coverMissing.add(t.id);
        }
      }
    }

    const concurrency = 4;
    final sw = Stopwatch()..start();
    await Future.wait(List.generate(concurrency, (_) => worker()));
    debugPrint(
        '[perf] 封面提取完成: ${todo.length} 首, ${sw.elapsedMilliseconds}ms '
        '(并发 $concurrency)');
    _librarySC.add(null);
  }

  int _coverApplied = 0;
  void _applyCoverUrl(Track oldT, String path) {
    if (oldT.coverUrl == path) return;
    final updated = oldT.copyWith(coverUrl: path);
    _library = _replaceTrack(_library, oldT, updated);
    _queueBase = _replaceTrack(_queueBase, oldT, updated);
    if (_queueIndex != null) {
      _queue = _replaceTrack(_queue, oldT, updated);
    }
    // 写回 DB：封面路径跨重启持久（否则重启后网络源曲目封面全部丢失）。
    unawaited(TrackRepository.updateCoverUrl(oldT.id, path).catchError((Object e) {
      debugPrint('coverUrl persist failed for ${oldT.id}: $e');
    }));
    // 增量广播：每 32 首刷新一次，避免海量曲目一次性刷新造成的卡顿
    _coverApplied++;
    if (_coverApplied % 32 == 0) _librarySC.add(null);
  }

  List<Track> _replaceTrack(List<Track> list, Track oldT, Track newT) {
    var changed = false;
    final out = list.map((x) {
      if (x.id == oldT.id) {
        changed = true;
        return newT;
      }
      return x;
    }).toList();
    return changed ? out : list;
  }

  // ---- Network sources (WebDAV / NAS / Subsonic) -------------------------

  /// 扫描 WebDAV 服务器并导入曲库（按 id 去重 + 写库）。返回扫描到的曲目。
  Future<List<Track>> importWebdav() async {
    final tracks = await WebdavService.scanWebdav();
    if (tracks.isNotEmpty) {
      addLibraryFiles(tracks);
      try {
        await TrackRepository.syncScan(tracks, source: TrackSource.webdav);
      } catch (e) {
        _reportError('WebDAV 曲库写入失败，导入结果未保存', e);
      }
    }
    _librarySC.add(null);
    // 后台提取 WebDAV 封面（Range 读头/尾解析，完成后增量广播刷新）
    if (tracks.isNotEmpty) extractCoversFor(tracks);
    await _cleanOrphanCaches();
    return tracks;
  }

  /// 扫描 NAS (SMB) 共享并导入曲库（按 id 去重 + 写库）。返回扫描到的曲目。
  Future<List<Track>> importNas() async {
    final tracks = await NasService.scan();
    if (tracks.isNotEmpty) {
      addLibraryFiles(tracks);
      try {
        await TrackRepository.syncScan(tracks, source: TrackSource.nas);
      } catch (e) {
        _reportError('NAS 曲库写入失败，导入结果未保存', e);
      }
    }
    _librarySC.add(null);
    // 后台提取 NAS 封面（远程读头/尾字节解析，完成后增量广播刷新）
    if (tracks.isNotEmpty) extractCoversFor(tracks);
    await _cleanOrphanCaches();
    return tracks;
  }

  /// 扫描 Subsonic 音乐服务器并导入曲库（按 id 去重 + 写库）。返回扫描到的曲目。
  Future<List<Track>> importSubsonic() async {
    final tracks = await SubsonicService.scanLibrary();
    if (tracks.isNotEmpty) {
      addLibraryFiles(tracks);
      try {
        await TrackRepository.syncScan(tracks, source: TrackSource.subsonic);
      } catch (e) {
        _reportError('Subsonic 曲库写入失败，导入结果未保存', e);
      }
    }
    _librarySC.add(null);
    await _cleanOrphanCaches();
    return tracks;
  }

  /// Begin playing [list] starting at [index], honoring shuffle state.
  void playFrom(List<Track> list, int index) {
    _queueBase = list;
    if (_shuffle) {
      _queue = _shuffled(list, index >= 0 && index < list.length
          ? list[index]
          : null);
      _queueIndex = 0;
    } else {
      _queue = list;
      _queueIndex = index;
    }
    if (_queueIndex != null) playIndex(_queueIndex!);
  }

  Future<void> playIndex(int index) async {
    if (index < 0 || index >= _queue.length) {
      debugPrint('[playIndex] index $index out of range (len=${_queue.length})');
      return;
    }
    _queueIndex = index;
    _indexSC.add(_queueIndex);
    _position = Duration.zero;
    _positionSC.add(_position);
    _duration = Duration.zero;
    _durationSC.add(_duration);

    final t = _queue[index];
    debugPrint('[playIndex] idx=$index source=${t.source.name} '
        'filePath=${t.filePath} remotePath=${t.remotePath}');
    // 网络扫描期已知的真实时长先填入，避免进度条先 0:00 再跳变。
    if (t.durationHint != null && t.durationHint! > Duration.zero) {
      _duration = t.durationHint!;
      _durationSC.add(_duration);
    }
    await _playTrack(t);
    _loadedTrackId = t.id;
    _pendingSeek = null; // 切换/新播均从头，清掉恢复待 seek
    _loadLyrics(t);
    _persistPlayback();
  }

  /// 节流落盘播放进度（每 3s 一次），避免高频 position 事件频繁写 SharedPreferences。
  void _throttledPersistPosition() {
    final now = DateTime.now();
    if (_lastPersistAt != null &&
        now.difference(_lastPersistAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastPersistAt = now;
    _persistPlayback();
  }

  /// 持久化当前播放上下文（曲目/进度/队列），供重启续播恢复。
  void _persistPlayback() {
    final t = currentTrack;
    final p = _prefs;
    if (t == null || p == null) return;
    unawaited(
      PlaybackSnapshot(
        trackId: t.id,
        position: _position,
        queueIds: _queue.map((e) => e.id).toList(),
      ).save(p),
    );
  }

  /// 启动恢复：曲库就绪后，重建上次的队列/当前曲目/进度（暂停态，不自动出声）。
  Future<void> _restorePlayback() async {
    final p = _prefs;
    if (p == null) return;
    final snap = PlaybackSnapshot.fromPrefs(p);
    final restored = restorePlayback(snap, _library);
    if (restored == null) {
      // 有快照但曲库已无该曲（被删）→ 清理残留；无快照则什么都不做
      if (snap != null) unawaited(PlaybackSnapshot.clear(p));
      return;
    }
    _queueBase = restored.queue;
    // shuffle 开启时同样对恢复队列应用乱序（当前曲目放首位，进度不受影响），
    // 否则跨重启后 shuffle 状态与队列顺序不一致。
    if (_shuffle) {
      final cur = restored.queue[restored.index];
      _queue = _shuffled(restored.queue, cur);
      _queueIndex = 0;
    } else {
      _queue = restored.queue;
      _queueIndex = restored.index;
    }
    _position = restored.position;
    _pendingSeek = restored.pendingSeek;
    // 广播，让 UI 立即显示当前曲目与进度（暂停态，不自动出声）
    _indexSC.add(_queueIndex);
    _positionSC.add(_position);
    if (_duration == Duration.zero &&
        restored.queue[restored.index].durationHint != null) {
      _duration = restored.queue[restored.index].durationHint!;
      _durationSC.add(_duration);
    }
  }

  void _setPlaying(bool v) {
    _playing = v;
    _playingSC.add(v);
  }

  /// 按曲目来源分发播放：本地直播；WebDAV/NAS 走 Rust 边下边播，失败回退
  /// 全量下载；Subsonic 先下载流再本地播放。
  Future<void> _playTrack(Track t) async {
    if (_engine == null || _engineInitError != null) {
      debugPrint('[_playTrack] engine unavailable (null=$_engine, '
          'initError=$_engineInitError), cannot play ${t.id}');
      return;
    }
    // 后台分析当前曲目（BPM/Key/能量），不阻塞播放；完成后通知播放页刷新徽章
    unawaited(_analyzeTrack(t));
    // STRM 指针文件：先解析出真实目标（源内路径或 URL）再按 kind 分发，
    // 不走常规的 nas/webdav 分支（其 remotePath 是 strm 文本文件本身）。
    if (t.isStrm) {
      await _playStrm(t);
      return;
    }
    switch (t.source) {
      case TrackSource.local:
        if (t.isCueTrack) {
          await _playCueTrack(t);
        } else if (t.filePath != null) {
          try {
            await _engine!.play(t.filePath!);
            _streaming = false;
            _setPlaying(true);
          } catch (e) {
            debugPrint('[_playTrack] engine.play failed: $e');
          }
        } else {
          debugPrint('[_playTrack] local track has no filePath: ${t.id}');
        }
      case TrackSource.webdav:
        await _playWebdav(t);
      case TrackSource.nas:
        await _playNas(t);
      case TrackSource.subsonic:
        await _playSubsonic(t);
    }
  }

  /// CUE 虚拟分轨播放：经引擎队列从指定分轨起播（core 展开 .cue 并遵循
  /// start/end 边界；position/duration/seek 均为虚拟轨相对值，UI 无需
  /// 特殊处理），随后清空引擎侧整碟剩余分轨——队列控制权归 Dart
  /// （随机/循环/播放列表语义以 Dart 队列为准，避免引擎自行顺碟推进）。
  /// 分轨曲终 → 引擎 stopped → Dart next() 切歌，与普通曲目同构。
  Future<void> _playCueTrack(Track t) async {
    try {
      await _engine!.playQueue([t.cuePath!], startIndex: t.cueTrackIndex!);
      final remaining = (t.cueTrackCount ?? 0) - t.cueTrackIndex! - 1;
      for (var i = 0; i < remaining; i++) {
        await _engine!.removeQueueEntry(1);
      }
      _streaming = false;
      _setPlaying(true);
    } catch (e) {
      debugPrint('[_playCueTrack] failed: $e');
    }
  }

  /// 后台分析 [t]（仅本地可分析路径：local 文件 / 已缓存的 WebDAV）。
  /// 分析完成后若仍是当前曲目则广播刷新 UI；失败静默。
  Future<void> _analyzeTrack(Track t) async {
    final path = await AnalysisService.instance.localPathFor(t);
    if (path == null) return;
    final result = await AnalysisService.instance.analyze(t.id, path);
    if (result == null) return;
    if (!_analysisSC.isClosed && currentTrack?.id == t.id) {
      _analysisSC.add(t.id);
    }
  }

  /// 同步读取某曲目的分析结果（播放页 build 用）。
  frb_analyze.AnalyzeResult? getAnalysis(String trackId) =>
      AnalysisService.instance.get(trackId);

  Future<void> _playWebdav(Track t) async {
    final davPath = t.remotePath;
    if (davPath == null) {
      debugPrint('[_playWebdav] remotePath null for ${t.id}');
      return;
    }
    final url = WebdavService.fullUrlFor(davPath);
    if (url == null) {
      debugPrint('[_playWebdav] fullUrl null for $davPath');
      return;
    }
    // 缓存命中：本地直播，不再重新从远端拉流
    // （兑现「边下边播读完 rename 成正式缓存、下次播放秒起」的承诺）。
    final cached = await WebdavService.cachedLocalPath(davPath);
    if (cached != null) {
      _streaming = false;
      await _engine!.play(cached);
      _setPlaying(true);
      return;
    }
    final cache = await WebdavService.cachePathFor(davPath);
    final err = await _engine!.playWebdavStream(
      url: url,
      username: WebdavService.username,
      password: WebdavService.password,
      formatHint: _formatHint(davPath),
      cacheFinalPath: cache,
      contentLength: t.fileSize,
    );
    if (err == null) {
      _streaming = true;
      _setPlaying(true);
      return;
    }
    debugPrint('webdav 流式播放失败，回退下载: $err');
    final local = await WebdavService.downloadToLocal(davPath);
    if (local != null) {
      _streaming = false;
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playWebdav] 回退下载失败: $davPath');
      // 流已停 + 下载失败：引擎静默。不复位的话 _playing 残留上一首的 true，
      // UI 显示"播放中"但无声。
      _streaming = false;
      _setPlaying(false);
    }
  }

  Future<void> _playNas(Track t) async {
    final smbPath = t.remotePath;
    if (smbPath == null) {
      debugPrint('[_playNas] remotePath null for ${t.id}');
      return;
    }
    // 缓存命中：本地直播（兑现边下边播缓存承诺，免去保活/重连/拉流）。
    final cached = await NasService.cachedLocalPath(smbPath);
    if (cached != null) {
      _streaming = false;
      await _engine!.play(cached);
      _setPlaying(true);
      return;
    }
    // 播放前确保 SMB 会话存活（扫描后可能已超时/断开）。
    final connErr = await NasService.connect();
    if (connErr != null) {
      debugPrint('[_playNas] connect failed: $connErr');
    }
    final cache = await NasService.cachePathFor(smbPath);
    final err = await _engine!.playSmbStream(
      smbPath: smbPath,
      formatHint: _formatHint(smbPath),
      cacheFinalPath: cache,
      contentLength: t.fileSize,
    );
    if (err == null) {
      _streaming = true;
      _setPlaying(true);
      return;
    }
    debugPrint('nas 流式播放失败，回退下载: $err');
    final local = await NasService.downloadToLocal(t);
    if (local != null) {
      _streaming = false;
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playNas] 回退下载失败: $smbPath');
      // 同 [_playWebdav]：流已停 + 下载失败，必须复位播放态。
      _streaming = false;
      _setPlaying(false);
    }
  }

  Future<void> _playSubsonic(Track t) async {
    final local = await SubsonicService.downloadStream(t);
    if (local != null) {
      _streaming = false;
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playSubsonic] downloadStream failed for ${t.id}');
    }
  }

  // ── STRM 指针播放（解析真实目标后复用现有流通道，不碰 core） ──

  /// 解析 strm 真实目标：扫描期已落地（targetUri/targetKind）则直接采用，
  /// 否则读 strm 文本兜底重新解析。
  Future<StrmTarget?> _resolveStrmTarget(Track t) async {
    if (t.targetUri != null && t.targetKind != null) {
      return StrmTarget(kind: t.targetKind!, path: t.targetUri!);
    }
    if (t.strmPath == null) return null;
    final text = await _readStrmText(t);
    if (text == null) return null;
    return parseStrmContent(
      text,
      fromWebdav: t.strmFromWebdav,
      strmPath: t.strmPath!,
    );
  }

  /// 读取 strm 文本（按所在源选择通道：WebDAV → readRemoteText，SMB → smbReadFile）。
  Future<String?> _readStrmText(Track t) async {
    try {
      final text = t.strmFromWebdav
          ? await WebdavService.readRemoteText(t.strmPath!)
          : await NasService.readStrmText(t.strmPath!);
      return text;
    } catch (e) {
      debugPrint('[_readStrmText] ${t.strmPath} -> $e');
      return null;
    }
  }

  /// STRM 播放分发：按真实目标 kind 复用对应流通道。
  Future<void> _playStrm(Track t) async {
    final target = await _resolveStrmTarget(t);
    if (target == null) {
      debugPrint('[_playStrm] 解析失败: ${t.id} (${t.strmPath})');
      return;
    }
    switch (target.kind) {
      case 'smb':
        await _playStrmSmb(target.path);
        break;
      case 'dav':
        await _playStrmDav(target.path);
        break;
      case 'http':
      case 'stream':
        // 外链：不携带 WebDAV 凭据（防泄漏），contentLength 未知。
        await _playStrmHttp(target.path, kind: target.kind);
        break;
      default:
        debugPrint('[_playStrm] 未知 kind: ${target.kind}');
    }
  }

  Future<void> _playStrmSmb(String smbPath) async {
    // 缓存命中：本地直播（SMB 目标曾边下边播过则秒起）。
    final cached = await NasService.cachedLocalPath(smbPath);
    if (cached != null) {
      _streaming = false;
      await _engine!.play(cached);
      _setPlaying(true);
      return;
    }
    final connErr = await NasService.connect();
    if (connErr != null) debugPrint('[_playStrmSmb] connect failed: $connErr');
    final cache = await NasService.cachePathFor(smbPath);
    final err = await _engine!.playSmbStream(
      smbPath: smbPath,
      formatHint: _formatHint(smbPath),
      cacheFinalPath: cache,
      contentLength: null,
    );
    if (err == null) {
      _streaming = true;
      _setPlaying(true);
      return;
    }
    debugPrint('strm smb 流式失败，回退下载: $err');
    final local = await NasService.downloadToLocalPath(smbPath);
    if (local != null) {
      _streaming = false;
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playStrmSmb] 回退下载失败: $smbPath');
      _streaming = false;
      _setPlaying(false);
    }
  }

  Future<void> _playStrmDav(String davPath) async {
    final url = WebdavService.fullUrlFor(davPath);
    if (url == null) {
      debugPrint('[_playStrmDav] fullUrl null: $davPath');
      return;
    }
    // 缓存命中：本地直播（与 [_playWebdav] 同构）。
    final cached = await WebdavService.cachedLocalPath(davPath);
    if (cached != null) {
      _streaming = false;
      await _engine!.play(cached);
      _setPlaying(true);
      return;
    }
    final cache = await WebdavService.cachePathFor(davPath);
    final err = await _engine!.playWebdavStream(
      url: url,
      username: WebdavService.username,
      password: WebdavService.password,
      formatHint: _formatHint(davPath),
      cacheFinalPath: cache,
      contentLength: null,
    );
    if (err == null) {
      _streaming = true;
      _setPlaying(true);
      return;
    }
    debugPrint('strm dav 流式失败，回退下载: $err');
    final local = await WebdavService.downloadToLocal(davPath);
    if (local != null) {
      _streaming = false;
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playStrmDav] 回退下载失败: $davPath');
      _streaming = false;
      _setPlaying(false);
    }
  }

  Future<void> _playStrmHttp(String url, {required String kind}) async {
    final err = await _engine!.playWebdavStream(
      url: url,
      username: '',
      password: '',
      formatHint: _formatHint(url),
      cacheFinalPath: null,
      contentLength: null,
    );
    if (err == null) {
      _streaming = true;
      _setPlaying(true);
    } else {
      debugPrint('[_playStrmHttp] 播放失败 ($kind): $url -> $err');
      // 失败时确保播放态复位，避免 UI 停在“正在播放”但实际无声
      _streaming = false;
      _setPlaying(false);
    }
  }

  /// 从路径取扩展名（不含点）作解码器提示。
  String? _formatHint(String? path) {
    if (path == null) return null;
    final ext = p.extension(path).toLowerCase();
    return ext.isEmpty ? null : ext.substring(1);
  }

  Future<void> _loadLyrics(Track t) async {
    final id = t.id;
    final lines = await loadLyricsFor(t);
    // 竞态守卫：快速切歌时旧请求晚到，若已切到别的曲则丢弃，避免覆盖新歌词；
    // dispose 后 _lyricsSC 已关闭，add 会抛 StateError，需先判 isClosed。
    if (id != currentTrack?.id) return;
    if (!_lyricsSC.isClosed) _lyricsSC.add(lines);
  }

  Future<void> togglePlay() async {
    if (_queueIndex == null) {
      if (_queue.isNotEmpty) await playIndex(0);
      return;
    }
    if (_playing) {
      await _engine?.pause();
      _playing = false;
      _playingSC.add(false);
    } else {
      final t = currentTrack;
      if (t == null) return;
      if (_loadedTrackId != t.id) {
        // 引擎尚未加载该曲（如启动恢复后首次播放）→ 加载并 seek 到恢复进度
        await _playTrack(t);
        if (_pendingSeek != null) {
          await seek(_pendingSeek!);
          _pendingSeek = null;
        }
      } else {
        await _engine?.resume();
      }
      _playing = true;
      _playingSC.add(true);
    }
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    if (_queueIndex == null) {
      await playIndex(0);
      return;
    }
    if (_repeatMode == RepeatMode.one) {
      await playIndex(_queueIndex!);
      return;
    }
    final ni = _queueIndex! + 1;
    if (ni >= _queue.length) {
      if (_repeatMode == RepeatMode.all) {
        await playIndex(0);
      } else {
        _stopRequested = true;
        await _engine?.stop();
        _playing = false;
        _playingSC.add(false);
      }
    } else {
      await playIndex(ni);
    }
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (_queueIndex == null) {
      await playIndex(0);
      return;
    }
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final pi = _queueIndex! - 1;
    await playIndex(pi < 0 ? _queue.length - 1 : pi);
  }

  /// 曲目自然结束后的切歌由引擎 stopped 事件在 [_onEngineEvent] 中处理。
  Future<void> seek(Duration d) async {
    _position = d;
    _positionSC.add(d);
    if (_pendingSeek != null) _pendingSeek = d; // 恢复进度随拖动更新
    _persistPlayback();
    final t = currentTrack;
    if (_streaming &&
        t != null &&
        (t.isStrm ||
            t.source == TrackSource.nas ||
            t.source == TrackSource.webdav)) {
      // 流式源不可 seek（core 流式解码无 current_entry，网络流非 seekable）：
      // 对齐 mobile：后台下载整曲 → 切本地播放 + seek。下载期间流继续播放，
      // 目标可被后续拖动覆盖（单飞 + pending target）。
      _pendingStreamSeek = d;
      _scheduleStreamSeek(t);
      return;
    }
    // 用毫秒换算，保留亚秒精度（inSeconds 会截断到整秒）。
    await _engine?.seek(d.inMilliseconds / 1000.0);
  }

  /// 流式播放中的 seek 回退（对齐 mobile `_scheduleStreamSeek`）：
  /// 后台下载整曲到本地缓存（期间旧流继续播放），完成后切本地播放并
  /// seek 到最新目标。
  /// 不再用「重启流 + 解码跳帧」方案——跳帧必须先完整拉到目标位置之前
  /// 的所有字节，拖动靠后位置时超过 core 的 ready 超时（6s）直接哑火
  /// （历史事故：拖动进度后歌曲不播放）。
  void _scheduleStreamSeek(Track t) {
    if (_streamSeekPending) return;
    _streamSeekPending = true;
    unawaited(
      _runStreamSeek(t).whenComplete(() => _streamSeekPending = false),
    );
  }

  Future<void> _runStreamSeek(Track t) async {
    while (_pendingStreamSeek != null && currentTrack?.id == t.id) {
      final target = _pendingStreamSeek!;
      _pendingStreamSeek = null;
      // 按源分支下载本地副本：SMB 走 NasService，WebDAV 走 WebdavService；
      // STRM 用解析出的真实目标（remotePath 是 strm 文本本身，不能用）。
      final String? path;
      if (t.isStrm) {
        final st = await _resolveStrmTarget(t);
        if (st == null) return;
        if (st.kind == 'stream') {
          // 电台流不可 seek（无限流无文件可下），保持流式继续播
          debugPrint('[seek] STRM 电台流不支持跳转，保持播放: ${t.title}');
          return;
        }
        path = switch (st.kind) {
          'smb' => await NasService.downloadToLocalPath(st.path),
          'dav' => await WebdavService.downloadToLocal(st.path),
          _ => await _downloadHttpUrl(st.path),
        };
      } else {
        path = switch (t.source) {
          TrackSource.nas => await NasService.downloadToLocal(t),
          TrackSource.webdav =>
            await WebdavService.downloadToLocal(t.remotePath ?? ''),
          _ => null,
        };
      }
      if (currentTrack?.id != t.id) return; // 下载期间已切歌：丢弃
      if (path == null) {
        // 下载失败：保持流式继续播，仅提示（不打断播放）
        debugPrint('[seek] 流式 seek 回退下载失败: ${t.title}');
        if (!_errorSC.isClosed) {
          _errorSC.add('无法跳转到「${t.title}」：下载失败');
        }
        return;
      }
      // 下载期间用户可能再次拖动：用最新目标
      final finalTarget = _pendingStreamSeek ?? target;
      _pendingStreamSeek = null;
      // 切本地播放：engine.play 会拆掉旧流 → 引擎发的 stopped 为预期伪事件
      //（_lastStreamSeekAt 窗口内吞掉，不会误切歌）
      _lastStreamSeekAt = DateTime.now();
      _streaming = false;
      await _engine!.play(path);
      await _engine!.seek(finalTarget.inMilliseconds / 1000.0);
      _setPlaying(true);
      _pendingSeek = finalTarget;
      return;
    }
  }

  /// HTTP(S) URL 下载到本地 .stream_cache（STRM http 目标 seek 回退用）。
  /// 命中缓存直接返回；流式落盘 + `.part` 原子改名。
  final Map<String, String> _httpCache = {};

  Future<String?> _downloadHttpUrl(String url) async {
    final hit = _httpCache[url];
    if (hit != null && await File(hit).exists()) return hit;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/.stream_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = strmExtFromUrl(url);
      final target = '${dir.path}/${fnv1a(url)}$ext';
      final f = File(target);
      if (await f.exists() && await f.length() > 0) {
        _httpCache[url] = target;
        return target;
      }
      final client = http.Client();
      try {
        final resp = await client
            .send(http.Request('GET', Uri.parse(url)))
            .timeout(const Duration(minutes: 2));
        if (resp.statusCode != 200) return null;
        await resp.stream
            .timeout(const Duration(minutes: 2))
            .pipe(File('$target.part').openWrite());
      } finally {
        client.close();
      }
      if (await File('$target.part').length() == 0) {
        await File('$target.part').delete();
        return null;
      }
      await File('$target.part').rename(target);
      _httpCache[url] = target;
      return target;
    } catch (e) {
      debugPrint('[_downloadHttpUrl] $url -> $e');
      return null;
    }
  }

  /// Queue a track to play immediately after the current one.
  void playNext(Track t) {
    if (_queue.isEmpty) {
      _queueBase = [t];
      _queue = [t];
      _queueIndex = 0;
      playIndex(0);
      return;
    }
    // 插入播放队列：当前曲目之后。
    final at = (_queueIndex ?? -1) + 1;
    _queue = [..._queue.sublist(0, at), t, ..._queue.sublist(at)];
    // 插入基准队列：按当前曲目在 _queueBase 中的真实位置计算。
    // shuffle 模式下 _queue 与 _queueBase 顺序不同，不能复用队列下标。
    final baseAt = _queueBase.indexOf(currentTrack ?? t);
    final insertAt = baseAt < 0 ? _queueBase.length : baseAt + 1;
    _queueBase = [
      ..._queueBase.sublist(0, insertAt),
      t,
      ..._queueBase.sublist(insertAt),
    ];
    _indexSC.add(_queueIndex);
  }

  // ---- Favorites -----------------------------------------------------------

  bool isFavorite(Track t) => _favoriteIds.contains(t.id);

  Future<void> toggleFavorite(Track t) async {
    if (_favoriteIds.contains(t.id)) {
      _favoriteIds.remove(t.id);
    } else {
      _favoriteIds.add(t.id);
    }
    await _prefs?.setStringList('favorites', _favoriteIds.toList());
    _favoritesSC.add(null);
  }

  // ---- Playlists -----------------------------------------------------------

  Future<void> createPlaylist(String name) async {
    final pl = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '新建播放列表' : name.trim(),
    );
    _playlists = [..._playlists, pl];
    await _savePlaylists();
    _playlistsSC.add(null);
  }

  Future<void> deletePlaylist(String id) async {
    _playlists = _playlists.where((p) => p.id != id).toList();
    await _savePlaylists();
    _playlistsSC.add(null);
  }

  Future<void> addToPlaylist(String playlistId, String trackId) async {
    _playlists = _playlists.map((p) {
      if (p.id != playlistId || p.trackIds.contains(trackId)) return p;
      return p.copyWith(trackIds: [...p.trackIds, trackId]);
    }).toList();
    await _savePlaylists();
    _playlistsSC.add(null);
  }

  Future<void> _savePlaylists() async {
    await _prefs?.setStringList(
      'playlists',
      _playlists.map((p) => jsonEncode(p.toJson())).toList(),
    );
  }

  // ---- Modes & volume ------------------------------------------------------

  /// 只更新引擎音量（拖动过程中高频调用，不落盘）。
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    await _engine?.setVolume(_volume);
    _modeSC.add(null);
  }

  /// 持久化音量（拖动结束 onChangeEnd 时调用一次）。
  Future<void> persistVolume() async {
    await _prefs?.setDouble('volume', _volume);
  }

  Future<void> toggleShuffle() async {
    _shuffle = !_shuffle;
    final cur = currentTrack;
    if (_shuffle) {
      _queue = _shuffled(_queueBase, cur);
      _queueIndex = cur == null ? null : 0;
    } else {
      _queue = _queueBase;
      _queueIndex = cur == null ? null : _queueBase.indexOf(cur);
    }
    if (_queueIndex != null) _indexSC.add(_queueIndex);
    await _prefs?.setBool('shuffle', _shuffle);
    _modeSC.add(null);
  }

  Future<void> cycleRepeat() async {
    _repeatMode =
        RepeatMode.values[(_repeatMode.index + 1) % RepeatMode.values.length];
    await _prefs?.setString('repeatMode', _repeatMode.name);
    _modeSC.add(null);
  }

  List<Track> _shuffled(List<Track> list, Track? current) {
    final rest = list.where((t) => t != current).toList();
    rest.shuffle();
    return current == null ? rest : [current, ...rest];
  }

  Future<void> dispose() async {
    // 停引擎、关闭数据库，避免退出时残留播放线程与未关闭的 SQLite 连接
    await _engine?.stop();
    _engine?.dispose();
    await TrackRepository.close();
    await _positionSC.close();
    await _durationSC.close();
    await _playingSC.close();
    await _indexSC.close();
    await _lyricsSC.close();
    await _favoritesSC.close();
    await _playlistsSC.close();
    await _modeSC.close();
    await _librarySC.close();
    await _errorSC.close();
    await _analysisSC.close();
    await _spectrumSC.close();
  }
}
