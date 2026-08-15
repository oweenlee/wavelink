import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../../../../domain/models/song.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../../data/services/native_audio_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../data/services/webdav_service.dart';
import '../../../../data/services/import_service.dart';
import '../../../../data/services/lrc_parser.dart';
import '../../../../data/repositories/audio_engine_repository.dart';
import '../../../../data/services/rust_service.dart'
    show AnalyzeResult, readMetadata;
import '../../../../data/services/strm_resolver.dart';
import '../../../core/providers/repositories.dart';
import '../backends/playback_backend.dart';
import '../../settings/view_models/dsp_provider.dart';
import 'queue_provider.dart';
import '../../../../data/services/log.dart';

class PlayerState {
  final bool isPlaying;
  final double position;
  final double volume;
  final Song? currentSong;
  final List<LyricLine>? lyrics;
  final EngineTelemetry telemetry;

  /// bit-perfect / 采样率跟随（由 PlaybackController 从偏好同步）。
  /// 开启后切歌时把输出速率对齐到文件速率（iOS 经 AVAudioSession），相等时不重采样。
  final bool bitPerfect;

  /// ReplayGain 开关（由 PlaybackController 从偏好同步，供设置页响应式显示）
  final bool replayGain;

  /// 封面模糊程度（同上，设置页滑块用）
  final double coverBlur;

  const PlayerState({
    this.isPlaying = false,
    this.position = 0.0,
    this.volume = 0.8,
    this.currentSong,
    this.lyrics,
    this.telemetry = EngineTelemetry.idle,
    this.bitPerfect = false,
    this.replayGain = true,
    this.coverBlur = 0.7,
  });

  double get progress {
    final song = currentSong;
    if (song == null) return 0.0;
    return position / song.duration.inMilliseconds;
  }

  int get currentLyricLine {
    final lines = lyrics;
    if (lines == null || lines.isEmpty) return -1;
    final pos = position; // ms
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].timeMs <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  static const Object _sentinel = Object();

  /// [currentSong]/[lyrics] 支持显式传 null 清空（哨兵区分「未传」与「传 null」）。
  PlayerState copyWith({
    bool? isPlaying,
    double? position,
    double? volume,
    Object? currentSong = _sentinel,
    Object? lyrics = _sentinel,
    EngineTelemetry? telemetry,
    bool? bitPerfect,
    bool? replayGain,
    double? coverBlur,
  }) {
    return PlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      volume: volume ?? this.volume,
      currentSong: identical(currentSong, _sentinel)
          ? this.currentSong
          : currentSong as Song?,
      lyrics: identical(lyrics, _sentinel)
          ? this.lyrics
          : lyrics as List<LyricLine>?,
      telemetry: telemetry ?? this.telemetry,
      bitPerfect: bitPerfect ?? this.bitPerfect,
      replayGain: replayGain ?? this.replayGain,
      coverBlur: coverBlur ?? this.coverBlur,
    );
  }
}

class PlayerNotifier extends Notifier<PlayerState> {
  final NativeAudioService _nativeAudio = NativeAudioService();
  StreamSubscription<AudioEvent>? _eventSub;
  Timer? _progressTimer;
  bool _nativeReady = false;
  int _playToken = 0;

  /// 进度条是否正在拖动。拖动中 [_tick] 必须跳过引擎位置覆写，
  /// 否则 250ms 轮询会把滑块弹回真实播放位置，造成拉锯跳动。
  bool _dragging = false;

  /// 当前曲是否已预取过下一曲（每首只预取一次）。
  /// shuffle 模式下下一曲随机，预取一首是尽力而为的优化。
  bool _prefetchedNext = false;

  /// 上一次推送到原生层（Android 媒体通知歌词）的歌词行文本，行级去抖。
  /// 仅 Android 用（实时滚动）；iOS 灵动岛已回退系统媒体模板，无此功能。
  String _lastLyricText = '';

  /// 当前曲是否走 SMB 边下边播（引擎读流播放，后台并行写缓存）。
  /// 供 [_tick] 在流式 error 事件时回退全量下载并抑制后续 stopped 切歌。
  bool _playingFromStream = false;

  /// 流式 error 已处理：随后的 stopped 事件须被吞掉，避免回退下载刚完成就
  /// 又触发 onTrackEnd 切歌。回退播放成功/失败后复位。
  bool _streamErrorHandling = false;

  /// 流式播放中发起 seek 的等待目标（ms）。stream 不可 seek（core 的 seek
  /// 依赖本地文件重建解码器），拖动时先下载本地文件，完成后切本地播放
  /// 并 seek 到最新目标；下载期间 stream 继续播放。
  double? _pendingStreamSeekMs;

  /// 流式 seek 下载/切换是否进行中（防重入）。
  bool _streamSeekPending = false;

  /// 当前 STRM 歌解析出的目标（kind: smb/dav/http + 路径/URL）。
  /// 每次播放时重新解析；seek 回退（[_scheduleStreamSeek]）依赖它。
  ({String kind, String path, String? extInfTitle, int? extInfSecs})? _strmTarget;

  /// 引擎是否已装载当前曲目。false 时即使 position>0 也不能 resume（引擎空），
  /// 需走完整装载流程再 seek——断点续播恢复场景依赖此判定。
  bool _engineLoaded = false;

  /// 当前曲目已解析的本地可播路径（ReplayGain 运行中切换开关时重读标签用）
  String? _lastResolvedPath;

  /// 断点续播兜底节流：距上次持久化超过 5s 才写一次（避免每 250ms tick 刷盘）
  int _lastResumeSave = 0;

  // ── 引擎遥测（乐器面板）──
  Timer? _telemetryTimer;
  int _lastUnderrun = 0;
  int _currentFileRate = 0;

  /// Android 设备原生输出采样率（初始化时查询，默认 44100）。
  /// 引擎产出速率与 AudioTrack 速率都用它，消掉强制 44.1k 双重重采样。
  int _nativeOutRate = 44100;

  Future<void> Function(Song) startDecoderHook = (_) async {};
  VoidCallback? onTrackEnd;
  VoidCallback? onNext;
  VoidCallback? onPrevious;

  AudioEngineRepository get _engineRepo =>
      ref.read(audioEngineRepositoryProvider);

  /// 传输层后端（play/pause/seek/位置/事件）；引擎专属能力
  /// （DSP/probe/遥测/ReplayGain）仍走 [_engineRepo] 按能力守卫调用。
  PlaybackBackend get _backend => ref.read(playbackBackendProvider);

  @override
  PlayerState build() {
    // dispose 回调内禁用 ref.read，提前捕获后端引用
    final backend = ref.read(playbackBackendProvider);
    ref.onDispose(() {
      _progressTimer?.cancel();
      _telemetryTimer?.cancel();
      _eventSub?.cancel();
      backend.dispose();
      _nativeAudio.dispose();
    });
    return const PlayerState();
  }

  void setBitPerfect(bool v) {
    state = state.copyWith(bitPerfect: v);
  }

  /// 以下三个仅用于设置页响应式展示（值以偏好为唯一事实源，
  /// 由 PlaybackController 同步写入）：
  void setReplayGain(bool v) => state = state.copyWith(replayGain: v);
  void setCoverBlur(double v) => state = state.copyWith(coverBlur: v);

  /// 有效 bit-perfect：请求偏好 && 实际链路 && 无 DSP 改动信号。
  /// - 速率维度：文件速率 == 实际输出速率（不等于时引擎在重采样）
  /// - Android：需实际 Exclusive 直通（mode=1）；Shared 降级不算
  /// - iOS：速率匹配即 bit-exact（无独占概念，不做独占宣称）
  /// - DSP：任一环节在动信号（EQ/Crossfeed/Widener/Limiter/Dither）即非
  ///   bit-perfect（引擎在 bit_perfect 下会自动 bypass，UI 如实反映）
  bool get effectiveBitPerfect {
    if (!state.bitPerfect) return false;
    final t = state.telemetry;
    if (t.fileRate <= 0 || t.fileRate != t.outputRate) return false;
    if (Platform.isAndroid && t.outputMode != 1) return false;
    final dsp = ref.read(dspProvider).dspSettings;
    if (dsp.enabled ||
        dsp.crossfeed ||
        dsp.widener ||
        dsp.limiter ||
        dsp.dither) {
      return false;
    }
    return true;
  }

  /// DSP 是否在动信号（供指示器说明"被旁路/生效中"）
  bool get dspAffectingSignal {
    final dsp = ref.read(dspProvider).dspSettings;
    return dsp.enabled ||
        dsp.crossfeed ||
        dsp.widener ||
        dsp.limiter ||
        dsp.dither;
  }

  void setCurrentSong(Song? song) {
    state = state.copyWith(currentSong: song);
  }

  AnalyzeResult? getAnalysis(String songId) => _engineRepo.getAnalysis(songId);

  Future<void> init() async {
    try {
      await _nativeAudio.init();
      _nativeReady = true;
      _eventSub = _nativeAudio.events.listen((event) {
        if (event is RemoteCommand) {
          _handleRemoteCommand(event);
        }
      });
      if (_engineRepo.rustAvailable) {
        // Android：以设备原生输出采样率初始化引擎（查询返回 0 时走默认路径，
        // iOS 速率由 Swift 经 set_hw_sample_rate 提供，不受影响）。
        final nativeRate = await _nativeAudio.getNativeOutputRate();
        if (nativeRate > 0) {
          _nativeOutRate = nativeRate;
          await _engineRepo.initEngineAt(nativeRate);
        } else {
          await _engineRepo.initEngine();
        }
      }
    } catch (e) {
      Log.e('Audio', '初始化原生音频失败: $e');
    }
  }

  void play() {
    if (state.currentSong == null) return;
    if (_engineLoaded && state.position > 0 && !state.isPlaying) {
      // 恢复播放（不从头开始）
      togglePlay();
    } else {
      // 引擎未装载（如启动后恢复的断点曲目）：完整装载后 seek 到保存位置
      _playCurrent(initialSeekMs: state.position);
    }
  }

  void playSong(Song song) {
    final previous = state.currentSong;
    state = state.copyWith(currentSong: song, position: 0.0);
    _playCurrent(fallbackSong: previous);
    saveResume();
  }

  /// [fallbackSong]：切歌时传入旧曲。若新歌路径解析失败（SMB 下载失败/
  /// 文件不存在等），引擎根本没切歌（还在播 [fallbackSong]），此时回滚 UI
  /// 恢复旧曲，避免"底部横条变了但声音没变"的错位。
  Future<void> _playCurrent({
    double initialSeekMs = 0,
    Song? fallbackSong,
  }) async {
    final song = state.currentSong;
    if (song == null) return;
    final token = ++_playToken;
    _prefetchedNext = false;
    _lastLyricText = '';
    // 歌词预取：与音频解析链路并行发起远端 .lrc 读取（SMB/WebDAV/
    // STRM 各自按源走网络），结果写 `.lrc_cache`；解析链路末尾
    // _loadLyrics 命中缓存秒回，歌词随播放同步上屏，不再等
    // "先出声 → 再等远端歌词几秒"的断层。
    unawaited(_prefetchRemoteLyrics(song));
    // 播放链路计时诊断：点击/切歌 → engine play 各阶段耗时
    final t0 = DateTime.now();
    void probeStage(String stage, [DateTime? from]) {
      final f = from ?? t0;
      Log.d(
        'Audio',
        '[pt] $stage: ${DateTime.now().difference(f).inMilliseconds}ms '
            '(${song.id} ${song.title})',
      );
    }

    _progressTimer?.cancel();
    state = state.copyWith(position: 0.0);

    // 立即静音当前声音（Rust 引擎 pause 保留输出流）：否则在解析/下载新歌
    // 期间旧歌继续响，切换才有延迟感；且切歌瞬间旧 ringbuf 被覆盖会爆音。
    final tPause = DateTime.now();
    await _backend.pause();
    await _nativeAudio.stop();
    probeStage('pause/stop 完成', tPause);
    if (token != _playToken || !ref.mounted) return;
    // 切歌窗口内实际无声：isPlaying 与锁屏（stop 已置暂停态）同步，
    // 避免 app 内"播放中"/锁屏"已暂停"按钮背离（SMB 下载慢时尤为明显）。
    state = state.copyWith(isPlaying: false);

    // 解析本地可播放路径：SMB 远端先按需下载，HTTP 流式源先下载到本地缓存。
    // SMB 优先"边下边播"：已缓存 → 本地 play（秒起）；未缓存 → enginePlaySmbStream
    // 流式播放（首帧即出声，后台并行写缓存）；流式不可用 → 回退全量下载。
    String? resolvedPath;
    _playingFromStream = false;
    _strmTarget = null;
    if (song.smbPath != null && song.smbPath!.isNotEmpty) {
      resolvedPath = await _resolveSmbPlayable(song.smbPath!);
    } else if (song.davPath != null && song.davPath!.isNotEmpty) {
      resolvedPath = await _resolveWebdavPlayable(song.davPath!, song.title);
    } else if (song.isStrm) {
      // STRM 指针：优先用扫描时 Resolver 落地的结果（targetUri/targetKind，
      // 元数据层已共用）；扫描时解析失败（内容异常）则兑底重读解析。
      final fallback = await _resolveStrmTarget(song);
      _strmTarget = song.targetUri != null && song.targetKind != null
          ? (
              kind: song.targetKind!,
              path: song.targetUri!,
              extInfTitle: null,
              extInfSecs: null,
            )
          : fallback;
      final target = _strmTarget;
      if (target == null) {
        Log.w('Audio', 'STRM 解析失败: ${song.title} (${song.strmPath})');
      } else {
        // #EXTINF 回填（仅兑底解析路径：扫描落地时已回填过）
        if (fallback != null &&
            applyExtInfToSong(
              song,
              StrmTarget(
                kind: fallback.kind,
                path: fallback.path,
                extInfTitle: fallback.extInfTitle,
                extInfSecs: fallback.extInfSecs,
              ),
            )) {
          state = state.copyWith(); // 刷新标题/时长
        }
        switch (target.kind) {
          case 'smb':
            resolvedPath = await _resolveSmbPlayable(target.path);
          case 'dav':
            resolvedPath = await _resolveWebdavPlayable(target.path, song.title);
          case 'http':
            // 文件型 URL：优先流式（Rust 带 WebDAV 配置凭据直喂 core，
            // 支持 Digest/Basic），失败回退全量下载。
            if (!await _startStrmStream(target.path)) {
              resolvedPath = await _downloadToCache(
                target.path,
                song.id,
                song.title,
              );
            }
          case 'stream':
            // 无扩展名 URL（网络电台流）：流式直喂 core，不下载不缓存
            // （无限流下载必超时）；失败无下载可回退，视为解析失败。
            if (!await _startStrmStream(target.path)) {
              Log.w('Audio', 'STRM 网络电台流启动失败，视为解析失败');
            }
        }
      }
    } else if (song.streamUrl != null && song.streamUrl!.isNotEmpty) {
      resolvedPath = await _downloadToCache(
        song.streamUrl!,
        song.id,
        song.title,
      );
    } else {
      resolvedPath = await _resolvePlayablePath(song.path);
      // 校验本地文件存在性（避免 Subsonic server-local 路径被误判）
      if (resolvedPath != null && !await File(resolvedPath).exists()) {
        resolvedPath = null;
      }
    }
    if (token != _playToken || !ref.mounted) return;
    // 防御：历史歌单脏数据可能混入 .lrc 歌词条目（旧版本扫描把歌词
    // 当音频收录，缓存里也可能已有下载的歌词文件）。非音频扩展名的
    // "可播放路径"直接视为解析失败，回滚旧曲而非喂给解码器报错。
    if (resolvedPath != null) {
      final ext = resolvedPath.split('.').last.toLowerCase();
      if (!ImportService.extensions.contains(ext)) {
        Log.w('Audio', '路径非音频扩展名 (.$ext)，视为解析失败: $resolvedPath');
        resolvedPath = null;
      }
    }
    probeStage('路径解析完成');

    // 流式播放中：无需本地路径，跳过 probe/seek/回滚分支
    if (_playingFromStream) {
      _currentFileRate = 0;
      if (token == _playToken) {
        // 排空积压引擎事件：SMB 流式启动失败会在 core 留下 error/stopped
        // 事件（3s ready 超时机制），期间 isPlaying=false 时 _tick 不轮询，
        // 事件积压；若不排空，本次播放成功后会被当作"当前曲曲终"误切歌
        // （历史事故：正常播放的本地歌被残留 stopped 事件误杀）。
        await _drainEngineEvents();
        _ghostStreamUntilMs = 0;
        state = state.copyWith(isPlaying: true);
        _startProgressTimer();
        await _nativeAudio.play(sampleRate: _nativeOutRate);
        _updateLockScreenMetadata();
        _nativeAudio.updatePosition(0);
        _analyzeCurrent();
        _loadLyrics(song, '');
        _engineLoaded = true;
      }
      return;
    }

    // 路径解析失败（SMB 下载失败/文件不存在/流式源不可用）→ 引擎没切歌，
    // 回滚 UI 到仍在播放的旧曲，避免"横条变了但音源没变"的错位。
    // 注意：上面已 pause 静音，回滚需 resume 恢复旧歌播放。
    if (resolvedPath == null) {
      Log.w('Audio', '无法播放 ${song.id}（resolvedPath=null），回滚到上一曲');
      ref
          .read(playErrorProvider.notifier)
          .report('无法播放「${song.title}」：文件不存在或下载失败');
      if (fallbackSong != null) {
        state = state.copyWith(currentSong: fallbackSong, isPlaying: true);
        await _backend.resume();
        // 原生侧同步恢复：上面已 _nativeAudio.stop()（iOS isPlayingFlag=false /
        // Android playing=false），只 resume 引擎不同步原生会导致锁屏/通知
        // 停在"非播放"态，与实际出声状态背离。
        _nativeAudio.resume();
        _nativeAudio.updatePosition(state.position);
        // 开头已 cancel 进度定时器：回滚后必须重启，否则进度冻结、曲终判断失效
        _startProgressTimer();
        saveResume();
      }
      return;
    }

    // 回写实际可播路径：持久化的 song.path 可能因 iOS 数据容器路径
    // 变更而失效，后续分析/封面提取/锁屏元数据都依赖它
    song.path = resolvedPath;

    // 探测文件采样率（轻量头部读取）：供乐器面板显示信号链，并复用于 bit-perfect 协调。
    if (_engineRepo.rustAvailable) {
      final tProbe = DateTime.now();
      _currentFileRate = await _engineRepo.probeSampleRate(resolvedPath);
      // 回填真实时长（估算占位 → 头部探测准确值，FLAC/WAV/M4A/DSF 有效，MP3 无 Xing 时保持估算）
      if (song.durationEstimated) {
        final realSecs = await _engineRepo.probeDurationSecs(resolvedPath);
        if (realSecs > 0) {
          song.duration = Duration(milliseconds: (realSecs * 1000).round());
          song.durationEstimated = false;
          state = state.copyWith(); // 刷新当前曲（队列/播放页时长）
        }
      }
      probeStage('采样率/时长探测完成', tProbe);
      if (token != _playToken || !ref.mounted) return;
    } else {
      _currentFileRate = 0;
    }

    // bit-perfect 协调：iOS 设 AVAudioSession 读回实际速率 → 引擎设输出速率。
    // 实际速率 == 文件速率时解码器不重采样（bit-perfect）；iOS 未满足时引擎按实际速率重采样保证播放正确。
    if (state.bitPerfect && _currentFileRate > 0) {
      final actualRate = await _nativeAudio.setOutputRate(
        _currentFileRate.toDouble(),
      );
      if (token != _playToken || !ref.mounted) return;
      if (actualRate > 0) {
        await _engineRepo.setOutputSampleRate(actualRate.round());
      }
    }

    if (_engineRepo.rustAvailable) {
      Log.d('Audio', 'engine play: $resolvedPath');
      _lastResolvedPath = resolvedPath;
      final tRg = DateTime.now();
      await _applyReplayGain(resolvedPath);
      probeStage('ReplayGain 应用完成', tRg);
      final tPlay = DateTime.now();
      await _backend.play(resolvedPath);
      probeStage('engine play 完成', tPlay);
      probeStage('总耗时（点击→engine play 返回）');
    } else {
      Log.w('Audio', 'engine play 跳过: rust=${_engineRepo.rustAvailable}');
    }
    if (token != _playToken || !ref.mounted) return;

    if (token == _playToken) {
      // 同 [_drainEngineEvents] 注释：清掉播放失败/下载期间的积压事件，
      // 避免旧曲/失败流的事件被误当作本次播放的曲终。
      await _drainEngineEvents();
      _ghostStreamUntilMs = 0;
      state = state.copyWith(isPlaying: true);
      _startProgressTimer();
      await _nativeAudio.play(sampleRate: _nativeOutRate);
      _updateLockScreenMetadata();
      // 断点续播：锁屏进度锚点直接落在恢复位置
      _nativeAudio.updatePosition(initialSeekMs > 0 ? initialSeekMs : 0);
      _analyzeCurrent();
      _loadLyrics(song, resolvedPath);
      _engineLoaded = true;
      if (initialSeekMs > 0) {
        _seekToPosition(initialSeekMs);
      }
    }
  }

  /// SMB 远端歌解析为可播放路径：缓存命中 → 本地（秒起）；未缓存 →
  /// 边下边播（首帧即出声，后台并行写缓存）；流式不可用 → 回退全量下载。
  /// 返回 null 表示解析失败。供 SMB 歌与 STRM 解析出的 SMB 目标共用。
  Future<String?> _resolveSmbPlayable(String smbPath) async {
    // 1. 缓存命中：纯本地返回，不碰 SMB 会话
    String? resolvedPath = await SmbService.cachedLocalPath(smbPath);
    if (resolvedPath == null) {
      // 2. 未缓存：先查命中（全量下载逻辑内的），若未命中走边下边播
      try {
        final ext = smbPath.split('.').last.toLowerCase();
        final cacheTarget = await SmbService.cacheTargetFor(smbPath);
        // 播放互斥标记：封面提取（后台任务）在此期间让路，
        // 避免竞争 NAS 连接数导致喂流超时（历史事故根因）
        SmbService.enterPlayback();
        try {
          await _engineRepo.playSmbStream(
            smbPath,
            ext.isEmpty ? null : ext,
            cacheTarget,
          );
          _playingFromStream = true;
        } finally {
          SmbService.exitPlayback();
        }
      } catch (e) {
        // 3. 流式启动失败（引擎未初始化/解码无法探测）→ 回退全量下载
        Log.w('Audio', 'SMB 边下边播不可用 ($e)，回退全量下载');
        // 幽灵流窗口：core 侧残留 stream 任务 ~3s 后会产生 error/stopped，
        // 置窗口标记供 _tick 吞掉（防误切歌），已产生的事件由播放前 drain 清空
        _ghostStreamUntilMs = DateTime.now().millisecondsSinceEpoch + 12000;
        resolvedPath = await SmbService.downloadToLocal(smbPath);
      }
    }
    return resolvedPath;
  }

  /// WebDAV 远端歌解析为可播放路径：缓存命中 → 本地；未缓存 → 流式播放
  /// （Rust reqwest 拉远端喂 core）；流式不可用 → 回退全量下载。
  /// 返回 null 表示解析失败。供 WebDAV 歌与 STRM 解析出的 WebDAV 目标共用。
  Future<String?> _resolveWebdavPlayable(String davPath, String title) async {
    final davSw = Stopwatch()..start();
    String? resolvedPath = await WebdavService.cachedLocalPath(davPath);
    if (resolvedPath == null) {
      try {
        final ext = davPath.split('.').last.toLowerCase();
        final cacheTarget = await WebdavService.cacheTargetFor(davPath);
        final url = WebdavService.fullUrlFor(davPath);
        if (url == null) throw Exception('WebDAV base URL 未配置');
        await _engineRepo.playWebdavStream(
          url,
          WebdavService.username,
          WebdavService.password,
          ext.isEmpty ? null : ext,
          cacheTarget,
        );
        _playingFromStream = true;
      } catch (e) {
        // 流式启动失败（引擎未初始化/认证失败/解码无法探测）→ 回退全量下载
        Log.w('Audio', 'WebDAV 边下边播不可用 ($e)，回退全量下载');
        _ghostStreamUntilMs = DateTime.now().millisecondsSinceEpoch + 12000;
        resolvedPath = await WebdavService.downloadToLocal(davPath);
      }
    }
    if (resolvedPath == null) {
      Log.w('Audio', 'WebDAV 路径解析失败（下载未成功）: $davPath');
    } else {
      Log.d(
        'Audio',
        'WebDAV 路径解析完成'
            '（${davSw.elapsedMilliseconds}ms）: $title',
      );
    }
    return resolvedPath;
  }

  /// 读取并解析 STRM 指针内容 → 目标媒体（kind: smb/dav/http + 路径/URL）。
  /// 内容为完整 http(s) URL 时走 http（下载通路）；否则按相对路径解析：
  /// 以 "/" 开头视为相对库根，否则相对 strm 文件所在目录，并规范化
  /// （解析 ./ ../）。目标扩展名非音频视为解析失败（防 lrc 式事故）。
  /// STRM 兑底解析：读文件内容 → Resolver 纯函数解析。
  /// 扫描时已落地（Song.targetUri/targetKind）的走落地结果，
  /// 此方法仅用于扫描时解析失败/内容异常的场合。
  Future<({String kind, String path, String? extInfTitle, int? extInfSecs})?>
      _resolveStrmTarget(Song song) async {
    final strmPath = song.strmPath;
    if (strmPath == null || strmPath.isEmpty) return null;
    final text = song.strmFromWebdav
        ? await WebdavService.readRemoteText(strmPath)
        : await SmbService.readRemoteText(strmPath);
    if (text == null) return null;
    final target =
        parseStrmContent(text, fromWebdav: song.strmFromWebdav, strmPath: strmPath);
    if (target == null) return null;
    return (
      kind: target.kind,
      path: target.path,
      extInfTitle: target.extInfTitle,
      extInfSecs: target.extInfSecs,
    );
  }

  /// STRM http/stream 目标流式启动：Rust reqwest 带 WebDAV 配置凭据
  /// 直喂 core（支持 Basic/Digest）。成功返回 true 并置 [_playingFromStream]；
  /// 失败设置幽灵窗口（core 残留 stream 任务事件需吞掉）并返回 false。
  /// ⚠️ 安全：STRM 文件内容可指向任意 http URL（网络电台/第三方源）。
  /// 凭据只对 WebDAV 服务器（host 与 baseUrl 一致）发送，否则 Rust 侧
  /// 收到 401 challenge 会把凭据发给攻击者服务器（凭据泄漏）。
  Future<bool> _startStrmStream(String url) async {
    try {
      final webdavBase = WebdavService.baseUrl;
      final sameHost = webdavBase != null &&
          Uri.tryParse(url)?.host.toLowerCase() ==
              Uri.tryParse(webdavBase)?.host.toLowerCase();
      await _engineRepo.playWebdavStream(
        url,
        sameHost ? WebdavService.username : '',
        sameHost ? WebdavService.password : '',
        null,
        null,
      );
      _playingFromStream = true;
      return true;
    } catch (e) {
      Log.w('Audio', 'STRM 流式启动失败 ($e)，回退/放弃');
      _ghostStreamUntilMs = DateTime.now().millisecondsSinceEpoch + 12000;
      return false;
    }
  }

  /// 按曲目标签应用 ReplayGain 响度归一化（切歌时逐首调用）。
  /// 开关关闭或无标签：增益置 0、峰值清除（引擎行为回到原始响度）。
  /// track 标签优先，其次 album（与桌面端一致）。
  Future<void> _applyReplayGain(String path) async {
    final enabled = ref.read(preferencesRepositoryProvider).replayGain;
    try {
      if (!enabled) {
        await _engineRepo.setReplaygainGain(0);
        await _engineRepo.setReplaygainPeak(null);
        return;
      }
      final rg = await _engineRepo.readReplaygain(path);
      final gain = rg.trackGainDb ?? rg.albumGainDb ?? 0.0;
      final peak = rg.trackPeak ?? rg.albumPeak;
      await _engineRepo.setReplaygainGain(gain);
      await _engineRepo.setReplaygainPeak(peak);
    } catch (e) {
      // 无标签/读取失败/引擎未就绪：回落原始响度，不阻塞播放
      Log.e('Audio', 'ReplayGain 应用失败，回落原始响度: $e');
      try {
        await _engineRepo.setReplaygainGain(0);
        await _engineRepo.setReplaygainPeak(null);
      } catch (_) {}
    }
  }

  /// 播放中切换 ReplayGain 开关：对当前曲目立即重新应用。
  void applyReplayGainNow() {
    final path = _lastResolvedPath;
    if (path == null || !_engineRepo.rustAvailable) return;
    _applyReplayGain(path);
  }

  void pause() {
    Log.d('Audio', 'Dart pause() 被调用');
    _progressTimer?.cancel();
    _backend.pause();
    _nativeAudio.pause();
    // 事件驱动锚点：暂停时推当前位置，锁屏进度不再靠 250ms 轮询
    _nativeAudio.updatePosition(state.position);
    state = state.copyWith(isPlaying: false);
    // 延迟对账：即时 pause 通道偶发未达原生时，1s 后以 Dart 状态为准修正
    // 锁屏按钮态（syncPlaying 幂等，正常路径下无操作）
    _scheduleStateSync();
    saveResume();
  }

  void togglePlay() {
    if (state.currentSong == null) return;
    if (state.isPlaying) {
      pause();
    } else if (state.position > 0 && _engineLoaded) {
      // 暂停恢复播放（不从头开始）
      _startProgressTimer();
      _backend.resume();
      _nativeAudio.resume();
      _nativeAudio.updatePosition(state.position);
      state = state.copyWith(isPlaying: true);
      _scheduleStateSync();
    } else {
      // 从未真正播放过（如程序启动后曲库当前曲尚未载入引擎，或断点恢复的曲目）：
      // resume 对空引擎无效，需走完整装载/播放流程，并在装载后 seek 到保存位置
      _playCurrent(initialSeekMs: state.position);
    }
  }

  void startPlayback() {
    _startProgressTimer();
    _nativeAudio.play(sampleRate: _nativeOutRate);
    _updateLockScreenMetadata();
    _nativeAudio.updatePosition(state.position);
    state = state.copyWith(isPlaying: true);
  }

  void setPosition(double ms) {
    state = state.copyWith(position: ms.clamp(0.0, double.infinity));
  }

  /// 进度条拖动态开关。开始拖动时置 true 冻结引擎位置覆写，
  /// 结束时置 false 恢复轮询（实际 seek 由调用方在 onChangeEnd 完成）。
  void setDragging(bool dragging) {
    _dragging = dragging;
    if (!dragging) {
      state = state.copyWith(position: state.position); // 触发一次刷新，落位最终值
    }
  }

  /// 持久化断点：当前队列 + 索引 + 位置。供暂停/切歌/tick 兜底调用。
  void saveResume() {
    final q = ref.read(queueProvider);
    if (q.queue.isEmpty || state.currentSong == null) return;
    ref
        .read(preferencesRepositoryProvider)
        .setResume(
          queueIds: q.queue.map((s) => s.id).toList(),
          index: q.currentIndex,
          positionMs: state.position,
        );
  }

  void seek(double value, {bool immediate = false}) {
    final song = state.currentSong;
    if (song == null) return;
    final posMs = value * song.duration.inMilliseconds;
    final pos = posMs.clamp(0.0, song.duration.inMilliseconds.toDouble());
    state = state.copyWith(position: pos);
    if (immediate) _seekToPosition(pos);
  }

  void seekToStart() {
    _seekToPosition(0);
  }

  void skipForward() {
    final song = state.currentSong;
    if (song == null) return;
    _seekToPosition(
      (state.position + 10000).clamp(
        0,
        song.duration.inMilliseconds.toDouble(),
      ),
    );
  }

  void skipBackward() {
    final song = state.currentSong;
    if (song == null) return;
    _seekToPosition(
      (state.position - 10000).clamp(
        0,
        song.duration.inMilliseconds.toDouble(),
      ),
    );
  }

  void _seekToPosition(double posMs) {
    final song = state.currentSong;
    if (song == null) return;
    final pos = posMs.clamp(0.0, song.duration.inMilliseconds.toDouble());
    state = state.copyWith(position: pos);
    if (!_nativeReady || !_backend.available) return;
    // 边下边播（SMB 流式）：引擎读流不可 seek（core seek 依赖本地文件
    // 重建解码器）。先下载本地文件再切本地播放并 seek，否则进度条
    // 拖了会被 250ms 轮询弹回（表现为"拖不动"）。
    if (_playingFromStream) {
      _pendingStreamSeekMs = pos;
      _scheduleStreamSeek(song);
      return;
    }
    _backend.seek(pos / 1000.0);
    // 原生侧清 AudioTrack/ringbuf 里 seek 前的旧 PCM，避免旧声音先播出造成错位。
    // iOS 无 seek 通道实现 → MissingPluginException 被 _safeCall 静默吞掉。
    _nativeAudio.seek(pos);
    // seek 后锁屏进度锚点必须立即更新（事件驱动，不再依赖 250ms 轮询）
    _nativeAudio.updatePosition(pos);
  }

  /// 流式播放中的 seek 回退：后台下载当前曲（期间 stream 继续播放），
  /// 完成后复用 [_playCurrent] 装载本地文件并 seek 到最新目标位置。
  /// 引擎命令队列有序（Play → Seek 顺序执行），不会丢 seek。
  Future<void> _scheduleStreamSeek(Song song) async {
    if (_streamSeekPending) return;
    _streamSeekPending = true;
    try {
      while (_pendingStreamSeekMs != null) {
        final target = _pendingStreamSeekMs!;
        _pendingStreamSeekMs = null;
        final smbPath = song.smbPath;
        final davPath = song.davPath;
        // 按源分支下载本地副本：SMB 走 SmbService，WebDAV 走 WebdavService；
        // STRM 歌用本次播放解析出的目标（smbPath/davPath 为空）。
        final String? path;
        if (smbPath != null && smbPath.isNotEmpty) {
          path = await SmbService.downloadToLocal(smbPath);
        } else if (davPath != null && davPath.isNotEmpty) {
          path = await WebdavService.downloadToLocal(davPath);
        } else if (song.isStrm && _strmTarget != null) {
          final t = _strmTarget!;
          if (t.kind == 'stream') {
            // 电台流不可 seek（无限流无文件可下），保持流式继续播
            Log.d('Audio', 'STRM 电台流不支持跳转，保持播放: ${song.title}');
            return;
          }
          path = switch (t.kind) {
            'smb' => await SmbService.downloadToLocal(t.path),
            'dav' => await WebdavService.downloadToLocal(t.path),
            _ => await _downloadToCache(t.path, song.id, song.title),
          };
        } else {
          return;
        }
        if (!ref.mounted || song.id != state.currentSong?.id) return;
        if (path == null) {
          // 下载失败：保持流式继续播，仅提示（不打断播放）
          Log.w('Audio', '流式 seek 回退下载失败: ${song.title}');
          ref
              .read(playErrorProvider.notifier)
              .report('无法跳转到「${song.title}」：下载失败');
          return;
        }
        // 切本地播放并 seek（_playCurrent 内部：pause 流 → 缓存命中 →
        // 本地 play → updatePosition(initialSeekMs) → _seekToPosition）
        // 下载期间用户可能再次拖动：用最新目标
        final finalTarget = _pendingStreamSeekMs ?? target;
        _pendingStreamSeekMs = null;
        await _playCurrent(initialSeekMs: finalTarget);
        return;
      }
    } finally {
      _streamSeekPending = false;
    }
  }

  void setVolume(double v) {
    final volume = v.clamp(0.0, 1.0);
    state = state.copyWith(volume: volume);
    _engineRepo.setVolume(volume);
  }

  /// 延迟状态对账：把 Dart 权威播放态推给原生（幂等，一致时无操作）。
  /// 兜底即时 pause/resume 通道调用偶发未达原生的场景，避免锁屏按钮背离。
  void _scheduleStateSync() {
    Timer(const Duration(seconds: 1), () {
      if (ref.mounted) _nativeAudio.syncPlaying(state.isPlaying);
    });
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tick();
    });
    _startTelemetryTimer();
  }

  // ── 引擎遥测轮询（乐器面板读数）──

  void _startTelemetryTimer() {
    _telemetryTimer?.cancel();
    _pollTelemetry(); // 立即来一次，避免面板延迟 500ms 才更新
    _telemetryTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _pollTelemetry();
    });
  }

  Future<void> _pollTelemetry() async {
    // 自守护：暂停/停止时停掉计时器（无需在每个 cancel 点手动清理）
    if (!state.isPlaying) {
      _telemetryTimer?.cancel();
      _telemetryTimer = null;
      if (state.currentSong == null) {
        // 无曲目：清为 idle
        if (state.telemetry.running || state.telemetry.underrunRecent != 0) {
          state = state.copyWith(telemetry: EngineTelemetry.idle);
        }
      } else if (state.telemetry.running) {
        // 曲目暂停：保留信号链展示（速率/underrun 统计——暂停时正是用户
        // 看面板的时候），只翻停止态，不清空
        state = state.copyWith(
          telemetry: EngineTelemetry(
            outputRate: state.telemetry.outputRate,
            fileRate: state.telemetry.fileRate,
            underrunTotal: state.telemetry.underrunTotal,
            underrunRecent: state.telemetry.underrunRecent,
            running: false,
            bufferMs: state.telemetry.bufferMs,
            outputMode: state.telemetry.outputMode,
          ),
        );
      }
      return;
    }
    if (!_engineRepo.rustAvailable) return;

    try {
      final results = await Future.wait([
        _engineRepo.getHwSampleRate(),
        _engineRepo.getUnderrunCount(),
        _engineRepo.getOutputMode(),
      ]);
      final outputRate = results[0];
      final underrunTotal = results[1];
      final outputMode = results[2];
      final running = await _engineRepo.isPlaying();

      final fileRate = _currentFileRate;

      final recent = (underrunTotal - _lastUnderrun).clamp(0, underrunTotal);
      _lastUnderrun = underrunTotal;

      final next = EngineTelemetry(
        outputRate: outputRate,
        fileRate: fileRate,
        underrunTotal: underrunTotal,
        underrunRecent: recent,
        running: running,
        bufferMs: EngineTelemetry.idle.bufferMs,
        outputMode: outputMode,
      );

      // 仅在读数变化时更新，避免无谓重建
      if (_telemetryChanged(next)) {
        state = state.copyWith(telemetry: next);
      }
    } catch (e) {
      Log.e('Audio', '遥测轮询失败: $e');
    }
  }

  bool _telemetryChanged(EngineTelemetry n) {
    final o = state.telemetry;
    return n.outputRate != o.outputRate ||
        n.fileRate != o.fileRate ||
        n.underrunTotal != o.underrunTotal ||
        n.underrunRecent != o.underrunRecent ||
        n.running != o.running ||
        n.outputMode != o.outputMode;
  }

  /// 幽灵流标记：SMB 流式启动失败后，core 侧残留 stream 任务会在
  /// ~3s 后产生 error/stopped 事件（play_stream 的 ready 超时机制），
  /// 期间若 isPlaying=false 则事件积压，恢复播放后会被误当"当前曲曲终"
  /// 导致误切歌（历史事故：正常播放的歌被残留 stopped 事件误杀）。
  /// 记录失败时刻 + 8s 窗口：窗口内的 stopped（非流式播放）一律吞掉；
  /// 已产生的事件由 [_drainEngineEvents] 在播放/回滚前清空。
  int _ghostStreamUntilMs = 0;

  /// 排空引擎事件通道中的积压事件。
  ///
  /// [_tick] 只在 isPlaying 时轮询；播放失败/下载回退期间（isPlaying=false）
  /// 引擎产生的 error/stopped（如 SMB 流式启动失败后 core 的 3s ready 超时
  /// 事件）会积压。若不清空，下一次播放成功后这些旧事件会被误判为
  /// "当前曲目曲终/错误"，导致正常播放的歌被强制切歌（历史事故）。
  /// 在每次 play 成功后、置 isPlaying=true 前调用，只清旧事件；
  /// 新曲的错误事件在 play 之后才产生，不会被误清。
  Future<void> _drainEngineEvents() async {
    try {
      for (var i = 0; i < 50; i++) {
        final e = await _backend.pollEvents();
        if (e == null) break;
        Log.d('Audio', '排空积压引擎事件: $e');
      }
    } catch (e) {
      Log.e('Audio', '排空引擎事件失败: $e');
    }
  }

  Future<void> _tick() async {
    if (!state.isPlaying) return;
    // 切歌竞态防护：_tick 是 async，await 期间用户可能已切歌
    // （_playCurrent 已把 position 重置为 0 / 状态已切到新曲）。
    // 记录播放代数，await 返回后不匹配则丢弃本次结果：
    // 1) pollEvents 拉到的是旧曲事件（误触发 stopped 切歌/流式回退）；
    // 2) positionSecs 返回的是引擎里旧曲的位置（进度条跳回旧值，
    //    且下载/解析期间无新 tick 纠正，旧值会一直挂着）。
    final tickToken = _playToken;
    try {
      final event = await _backend.pollEvents();
      if (tickToken != _playToken) return;
      if (event != null) {
        Log.d('Audio', 'engine event: $event');
      }
      if (event == 'stopped') {
        // 流式 error 已处理时吞掉 stopped：回退下载流程刚结束，不应再切歌
        if (_streamErrorHandling) {
          Log.d('Audio', '收到 stopped（流式回退中，吞掉不切歌）');
          return;
        }
        // 幽灵流窗口：SMB 流式启动失败后 core 残留 stream 任务产生的
        // stopped 与当前曲目无关，吞掉避免误切歌（真实曲终有位置判断兜底）。
        if (!_playingFromStream &&
            DateTime.now().millisecondsSinceEpoch < _ghostStreamUntilMs) {
          Log.d('Audio', '收到 stopped（幽灵流窗口内，吞掉不切歌）');
          return;
        }
        Log.d('Audio', '收到引擎 stopped 事件 → 队列结束，触发切歌/停止');
        _progressTimer?.cancel();
        state = state.copyWith(isPlaying: false);
        onTrackEnd?.call();
        return;
      } else if (event == 'error') {
        final err = await _backend.lastError();
        Log.e('Audio', '引擎错误: $err');
        // 流式播放失败（SMB 首块/解码失败）：回退全量下载重播当前曲
        if (_playingFromStream) {
          _playingFromStream = false;
          _streamErrorHandling = true;
          Log.w('Audio', '流式播放失败 ($err)，回退全量下载重播: ${state.currentSong?.title}');
          _progressTimer?.cancel();
          state = state.copyWith(isPlaying: false);
          final song = state.currentSong;
          if (song != null) {
            // 按源分支下载本地副本：SMB 走 SmbService，WebDAV 走 WebdavService
            String? cached;
            if (song.smbPath != null && song.smbPath!.isNotEmpty) {
              cached = await SmbService.downloadToLocal(song.smbPath!);
            } else if (song.davPath != null && song.davPath!.isNotEmpty) {
              cached = await WebdavService.downloadToLocal(song.davPath!);
            }
            _streamErrorHandling = false;
            if (cached != null) {
              // 下载成功 → 以本地文件路径重播当前曲（复用完整装载流程）
              await _backend.play(cached);
              // 清积压事件（断流的 stopped 可能还在通道里）再恢复播放，
              // 避免被误当曲终切歌；同时清幽灵窗口（已恢复正常播放）
              await _drainEngineEvents();
              _ghostStreamUntilMs = 0;
              state = state.copyWith(isPlaying: true);
              _startProgressTimer();
              await _nativeAudio.play(sampleRate: _nativeOutRate);
              _updateLockScreenMetadata();
              _nativeAudio.updatePosition(0);
              _analyzeCurrent();
              _loadLyrics(song, cached);
              _engineLoaded = true;
            } else {
              Log.e('Audio', '流式回退下载失败: ${song.title}');
              onTrackEnd?.call();
            }
          }
          return;
        }
      }
    } catch (e) {
      Log.e('Audio', '事件轮询失败: $e');
    }

    // 引擎位置（ms）。查询失败时保留上次合法值，绝不盲目累加：
    // 锁屏后台 Dart Timer 被节流、FRB 通道抖动时 positionSecs 可能异常，
    // 原实现 _position += 250 会随轮询累积虚高，越过时长线被误判为曲终而自停。
    // 拖动中：跳过引擎位置覆写，避免与手指拉锯跳动（seek 在 onChangeEnd 落定）。
    double? enginePosMs;
    if (_dragging) {
      state = state.copyWith(position: state.position);
    } else {
      try {
        enginePosMs = (await _backend.positionSecs()) * 1000;
        // 切歌竞态：await 期间 _playCurrent 已重置 position，引擎里
        // 还是旧曲位置（Play 命令未处理/解码未启动），丢弃过期查询
        if (tickToken != _playToken) return;
        // duration 为 0（STRM 电台流）时冻结进度：无限流无曲终，
        // 进度条/曲终判断均以 0 处理（避免 position/duration=∞ 满格）
        final cur = state.currentSong;
        state = state.copyWith(
          position:
              cur != null && cur.duration > Duration.zero ? enginePosMs : 0,
        );
      } catch (e) {
        Log.e('Audio', '位置查询失败，保留上次位置: ${state.position.toInt()}ms');
      }
    }

    final song = state.currentSong;
    // 曲终判断仅在引擎位置真实读取成功时进行，避免后台异常时误停。
    // duration 为 0（STRM 电台流无时长信息）时跳过——无限流没有曲终，
    // 切歌只能靠引擎 stopped 事件（手动切/断流）。
    if (song != null &&
        song.duration > Duration.zero &&
        enginePosMs != null &&
        enginePosMs >= song.duration.inMilliseconds) {
      Log.d(
        'Audio',
        '位置到达时长（${state.position.toInt()}ms >= '
            '${song.duration.inMilliseconds}ms）→ 视为曲终',
      );
      _progressTimer?.cancel();
      state = state.copyWith(isPlaying: false);
      onTrackEnd?.call();
      return;
    }

    // 锁屏进度改事件驱动（play/pause/seek/切歌时推锚点，系统按 rate 插值），
    // 不再随 250ms tick 调平台通道。
    state = state.copyWith(position: state.position); // 触发 UI 进度刷新

    // 断点续播兜底：每 5s 持久化一次当前位置（防 app 被杀丢进度）
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastResumeSave >= 5000) {
      _lastResumeSave = nowMs;
      saveResume();
      // 播放中周期对账：锁屏按钮态与 Dart 状态强制一致（原生侧判重幂等）
      _nativeAudio.syncPlaying(true);
    }

    _prefetchNextIfNeeded(song);

    // Android 媒体通知歌词：当前行文本变化时实时推送（行级去抖，避免
    // 250ms tick 反复打平台通道）。Android 无更新频率限制，展开式通知
    // 空间大，实时滚动体验好。iOS 无此功能（灵动岛已回退系统媒体模板，
    // 系统自动显示媒体控制，锁屏仅一张媒体卡片）。
    if (Platform.isAndroid) {
      final lineIdx = state.currentLyricLine;
      final lines = state.lyrics;
      if (lines != null && lineIdx >= 0 && lineIdx < lines.length) {
        final text = lines[lineIdx].text;
        if (text != _lastLyricText) {
          _lastLyricText = text;
          _nativeAudio.updateLiveLyrics(lyricLine: text);
        }
      }
    }
  }

  /// 下一曲预取：SMB / WebDAV 切歌需先整文件下载才能播（慢的直观来源），
  /// 播放进度过 60% 时后台提前下载下一曲，切歌直接命中缓存。
  /// downloadToLocal 内部按路径去重 + 缓存命中即返，重复调用无害。
  void _prefetchNextIfNeeded(Song? current) {
    if (_prefetchedNext) return;
    if (current == null || current.duration.inMilliseconds <= 0) return;
    if (state.position < current.duration.inMilliseconds * 0.6) return;
    final q = ref.read(queueProvider);
    if (q.queue.length < 2 || q.loopMode == LoopMode.single) return;
    final next = q.queue[ref.read(queueProvider.notifier).findNextIndex()];
    final smbPath = next.smbPath;
    final davPath = next.davPath;
    // STRM 歌：用 Resolver 落地的目标（仅 smb/dav 可预取下载；
    // http 走下载通路可预取；stream 电台流不可缓存跳过）
    final strmKind = next.isStrm ? next.targetKind : null;
    final strmUri = next.isStrm ? next.targetUri : null;
    if ((smbPath == null || smbPath.isEmpty) &&
        (davPath == null || davPath.isEmpty) &&
        (strmUri == null ||
            (strmKind != 'smb' && strmKind != 'dav' && strmKind != 'http'))) {
      return;
    }
    _prefetchedNext = true;
    Log.d('Audio', '预取下一曲: ${next.title}');
    unawaited(
      smbPath != null && smbPath.isNotEmpty
          ? SmbService.downloadToLocal(smbPath).catchError((Object _) => null)
          : davPath != null && davPath.isNotEmpty
              ? WebdavService.downloadToLocal(davPath)
                  .catchError((Object _) => null)
              : strmKind == 'smb'
                  ? SmbService.downloadToLocal(strmUri!)
                      .catchError((Object _) => null)
                  : strmKind == 'dav'
                      ? WebdavService.downloadToLocal(strmUri!)
                          .catchError((Object _) => null)
                      : _downloadToCache(strmUri!, next.id, next.title)
                          .catchError((Object _) => null),
    );
  }

  Future<void> _analyzeCurrent() async {
    final song = state.currentSong;
    if (song == null || !_engineRepo.rustAvailable) return;
    // 无本地文件路径（SMB 索引/流式源下载失败等）无法分析，跳过而非强解包崩溃
    if (song.path == null || song.path!.isEmpty) return;
    if (_engineRepo.hasAnalysis(song.id)) return;
    try {
      await _engineRepo.analyzeFile(song.id, song.path!);
      if (!ref.mounted) return;
      state = state.copyWith(); // 分析完成，触发 UI 刷新
    } catch (e) {
      Log.e('Audio', '分析音频失败: $e');
    }
  }

  /// 预取远端歌词到 `.lrc_cache`（与播放解析并行，见 [_loadLyrics] 注释）。
  /// 只处理 SMB/WebDAV/STRM 远端源；本地歌走本地 .lrc/内嵌，读取快无感。
  /// 与 [_loadLyrics] 共享同一缓存路径与并发去重，`_loadLyrics` 复用
  /// 预取的在途请求或命中缓存，避免双网络请求。
  Future<void> _prefetchRemoteLyrics(Song song) async {
    try {
      if (song.smbPath != null && song.smbPath!.isNotEmpty) {
        await _loadRemoteLyrics(song.smbPath!);
      } else if (song.davPath != null && song.davPath!.isNotEmpty) {
        await _loadWebdavLyrics(song.davPath!);
      } else if (song.isStrm && song.targetUri != null) {
        if (song.targetKind == 'smb') {
          await _loadRemoteLyrics(song.targetUri!);
        } else if (song.targetKind == 'dav') {
          await _loadWebdavLyrics(song.targetUri!);
        }
      }
    } catch (e) {
      Log.d('Audio', '歌词预取失败（不影响播放）: $e');
    }
  }

  /// 并发去重封装：同一远端路径的歌词预取/加载共享一次网络读取，
  /// 第二次调用直接复用进行中的 Future（结果一致，都写同一缓存）。
  final Map<String, Future<List<LyricLine>?>> _lyricsInFlight = {};

  Future<List<LyricLine>?> _prefetchRemoteLyricsOnce(
    String remotePath,
    Future<List<LyricLine>?> Function() loader,
  ) {
    final existing = _lyricsInFlight[remotePath];
    if (existing != null) return existing;
    final future = loader();
    // 结束后清除占位；不因失败保留（下次播放可重试）
    future.whenComplete(() => _lyricsInFlight.remove(remotePath));
    _lyricsInFlight[remotePath] = future;
    return future;
  }

  /// 加载歌词，来源优先级：
  /// 1) 本地歌词文件（导入时匹配的 lyricsPath / 音频旁同名 .lrc）
  /// 2) NAS 远端同名 .lrc（结果缓存到沙盒，一次读取后离线可用）
  /// 3) 内嵌元数据歌词（lofty 提取的 USLT / LYRICS / ©lyr）
  Future<void> _loadLyrics(Song song, String? audioPath) async {
    List<LyricLine>? lyrics;
    // 1) 本地歌词文件
    if (audioPath != null && audioPath.isNotEmpty) {
      try {
        final noExt = audioPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
        final candidates = <String>[
          if (song.lyricsPath != null) song.lyricsPath!,
          '$noExt.lrc',
          '$noExt.LRC',
        ];
        for (final p in candidates) {
          final file = File(p);
          if (await file.exists()) {
            final parsed = parseLrc(await file.readAsString());
            if (parsed.isNotEmpty) {
              lyrics = parsed;
              break;
            }
          }
        }
      } catch (e) {
        Log.e('Audio', '歌词加载失败: $e');
      }
    }
    // 2) 远端同名 .lrc（本地歌词缺失时）：SMB / WebDAV 各自按源读取；
    //    STRM 歌用 Resolver 落地的目标地址（targetUri/targetKind）
    if (lyrics == null) {
      if (song.smbPath != null && song.smbPath!.isNotEmpty) {
        lyrics = await _loadRemoteLyrics(song.smbPath!);
      } else if (song.davPath != null && song.davPath!.isNotEmpty) {
        lyrics = await _loadWebdavLyrics(song.davPath!);
      } else if (song.isStrm && song.targetUri != null) {
        final t = song.targetUri!;
        lyrics = song.targetKind == 'smb'
            ? await _loadRemoteLyrics(t)
            : song.targetKind == 'dav'
                ? await _loadWebdavLyrics(t)
                : null;
      }
    }
    // 3) 内嵌元数据歌词
    if (lyrics == null && audioPath != null && audioPath.isNotEmpty) {
      lyrics = await _loadEmbeddedLyrics(audioPath);
    }
    if (!ref.mounted) return;
    state = state.copyWith(lyrics: lyrics);
  }

  /// NAS 远端歌词：读取与音频同目录同名的 .lrc/.LRC，解析后缓存到
  /// 沙盒 `.lrc_cache/`（下次播放走缓存，不再发起 SMB 读取）。
  /// 经 [_prefetchRemoteLyricsOnce] 并发去重：预取进行中时复用同一请求。
  Future<List<LyricLine>?> _loadRemoteLyrics(String smbPath) =>
      _prefetchRemoteLyricsOnce(smbPath, () => _loadRemoteLyricsImpl(smbPath));

  Future<List<LyricLine>?> _loadRemoteLyricsImpl(String smbPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheFile = File(
        '${appDir.path}/.lrc_cache/${smbPath.hashCode}.lrc',
      );
      if (await cacheFile.exists()) {
        final parsed = parseLrc(await cacheFile.readAsString());
        if (parsed.isNotEmpty) return parsed;
      }
      final text = await SmbService.fetchRemoteLyrics(smbPath);
      if (text == null || text.trim().isEmpty) return null;
      final parsed = parseLrc(text);
      if (parsed.isNotEmpty) {
        final dir = cacheFile.parent;
        if (!await dir.exists()) await dir.create(recursive: true);
        await cacheFile.writeAsString(text);
      }
      return parsed;
    } catch (e) {
      Log.e('Audio', 'NAS 歌词读取失败: $e');
      return null;
    }
  }

  /// WebDAV 远端歌词：读取与音频同目录同名的 .lrc/.LRC（Range 读前部），
  /// 解析后缓存到沙盒 `.lrc_cache/`（下次播放走缓存，不再发起 HTTP）。
  /// 经 [_prefetchRemoteLyricsOnce] 并发去重：预取进行中时复用同一请求。
  Future<List<LyricLine>?> _loadWebdavLyrics(String davPath) =>
      _prefetchRemoteLyricsOnce(davPath, () => _loadWebdavLyricsImpl(davPath));

  Future<List<LyricLine>?> _loadWebdavLyricsImpl(String davPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheFile = File(
        '${appDir.path}/.lrc_cache/${davPath.hashCode}.lrc',
      );
      if (await cacheFile.exists()) {
        final parsed = parseLrc(await cacheFile.readAsString());
        if (parsed.isNotEmpty) return parsed;
      }
      final text = await WebdavService.fetchRemoteLyrics(davPath);
      if (text == null || text.trim().isEmpty) return null;
      final parsed = parseLrc(text);
      if (parsed.isNotEmpty) {
        final dir = cacheFile.parent;
        if (!await dir.exists()) await dir.create(recursive: true);
        await cacheFile.writeAsString(text);
      }
      return parsed;
    } catch (e) {
      Log.e('Audio', 'WebDAV 歌词读取失败: $e');
      return null;
    }
  }

  /// 内嵌元数据歌词：LRC 格式直接解析；无时间戳的纯文本歌词
  /// （USLT 等）按行顺序分配 1 秒间隔，随播放进度逐行高亮。
  Future<List<LyricLine>?> _loadEmbeddedLyrics(String audioPath) async {
    try {
      final meta = await readMetadata(audioPath);
      final text = meta.lyrics;
      if (text == null || text.trim().isEmpty) return null;
      final parsed = parseLrc(text);
      if (parsed.isNotEmpty) return parsed;
      final lines = text
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return null;
      return [
        for (var i = 0; i < lines.length; i++) LyricLine(i * 1000.0, lines[i]),
      ];
    } catch (e) {
      Log.e('Audio', '嵌入歌词读取失败: $e');
      return null;
    }
  }

  void _handleRemoteCommand(RemoteCommand cmd) {
    Log.d('Audio', '收到远程命令: ${cmd.command}');
    switch (cmd.command) {
      case 'play':
      case 'togglePlayPause':
        togglePlay();
        break;
      case 'pause':
        pause();
        break;
      case 'next':
        onNext?.call();
        break;
      case 'previous':
        onPrevious?.call();
        break;
      case 'seek':
        final target = cmd.seekPosition;
        if (target != null) {
          _seekToPosition(target * 1000);
        }
        break;
    }
  }

  /// 把歌曲路径解析为 Rust 可读的本地文件路径。
  /// iOS iPod library 的 ipod-library:// URL 需先导出为本地文件（结果缓存复用）；
  /// 普通文件路径原样返回。
  final Map<String, String> _resolvedPaths = {};

  /// HTTP(S) 流式 URL 下载到本地缓存目录。
  /// 缓存命中直接返回，避免重复下载。
  final Map<String, String> _streamCache = {};

  Future<String?> _downloadToCache(
    String url,
    String songId,
    String title,
  ) async {
    // 检查内存缓存
    final cached = _streamCache[songId];
    if (cached != null && await File(cached).exists()) return cached;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/.stream_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

      final ext = _extFromUrl(url);
      final cacheFile = File('${cacheDir.path}/$songId$ext');

      // 磁盘缓存命中
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        _streamCache[songId] = cacheFile.path;
        return cacheFile.path;
      }

      Log.d('Audio', '下载流式文件: $title');
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        Log.e('Audio', '下载失败 HTTP ${response.statusCode}');
        return null;
      }

      await cacheFile.writeAsBytes(response.bodyBytes);
      _streamCache[songId] = cacheFile.path;
      Log.d(
        'Audio',
        '下载完成: ${cacheFile.path} (${response.bodyBytes.length} bytes)',
      );
      return cacheFile.path;
    } catch (e) {
      Log.e('Audio', '流式下载失败: $e');
      return null;
    }
  }

  String _extFromUrl(String url) => strmExtFromUrl(url);

  Future<String?> _resolvePlayablePath(String? path) async {
    if (path == null) return null;
    if (!path.startsWith('ipod-library://')) return path;
    final cached = _resolvedPaths[path];
    if (cached != null) return cached;
    final resolved = await _nativeAudio.resolveLibraryAsset(path);
    if (resolved != null && resolved.isNotEmpty) {
      _resolvedPaths[path] = resolved;
      return resolved;
    }
    return null;
  }

  Future<void> _updateLockScreenMetadata() async {
    if (!_nativeReady) return;
    final song = state.currentSong;
    if (song == null) return;
    // 立即推送基础信息（不等封面提取）；有缓存封面直接带图，
    // 否则原生先按音频文件回退提取，封面就绪后再补推一次。
    await _nativeAudio.updateMetadata(
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration.inMilliseconds / 1000.0,
      filePath: song.path,
      coverPath: song.coverUrl,
    );
    if (song.coverUrl == null) {
      await _ensureCoverCached(song);
      // 仍是当前曲且封面刚就绪 → 补推带图元数据
      if (state.currentSong?.id == song.id && song.coverUrl != null) {
        await _nativeAudio.updateMetadata(
          title: song.title,
          artist: song.artist,
          album: song.album,
          duration: song.duration.inMilliseconds / 1000.0,
          filePath: song.path,
          coverPath: song.coverUrl,
        );
      }
    }
  }

  Future<void> _ensureCoverCached(Song song) async {
    if (!song.hasCover || song.path == null) return;
    if (song.coverUrl != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheFile = File('${appDir.path}/.covers/${song.path!.hashCode}.jpg');
    if (await cacheFile.exists()) {
      song.coverUrl = cacheFile.path;
      state = state.copyWith(); // 封面就绪，触发 UI 刷新
      return;
    }
    try {
      final bytes = await _engineRepo.getCoverBytes(song.path!);
      final cacheDir = Directory('${appDir.path}/.covers');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      await cacheFile.writeAsBytes(bytes);
      song.coverUrl = cacheFile.path;
      state = state.copyWith(); // 封面就绪，触发 UI 刷新
    } catch (e) {
      Log.e('Audio', '缓存封面失败: $e');
    }
  }
}

final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

/// 播放失败一次性提示（文件不存在/下载失败等）：PlayerNotifier 上报，
/// UI 层 ref.listen 弹 SnackBar 后 clear，避免静默回滚让用户困惑。
class PlayErrorNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void report(String msg) => state = msg;
  void clear() => state = null;
}

final playErrorProvider = NotifierProvider<PlayErrorNotifier, String?>(
  PlayErrorNotifier.new,
);
