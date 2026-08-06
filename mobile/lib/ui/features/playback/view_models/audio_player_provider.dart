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
import '../../../../data/services/lrc_parser.dart';
import '../../../../data/repositories/audio_engine_repository.dart';
import '../../../../data/services/rust_service.dart' show AnalyzeResult;
import '../../../core/providers/repositories.dart';
import '../../settings/view_models/dsp_provider.dart';
import 'queue_provider.dart';

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

  const PlayerState({
    this.isPlaying = false,
    this.position = 0.0,
    this.volume = 0.8,
    this.currentSong,
    this.lyrics,
    this.telemetry = EngineTelemetry.idle,
    this.bitPerfect = false,
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
    );
  }
}

class PlayerNotifier extends Notifier<PlayerState> {
  final NativeAudioService _nativeAudio = NativeAudioService();
  StreamSubscription<AudioEvent>? _eventSub;
  Timer? _progressTimer;
  bool _nativeReady = false;
  int _playToken = 0;

  /// 引擎是否已装载当前曲目。false 时即使 position>0 也不能 resume（引擎空），
  /// 需走完整装载流程再 seek——断点续播恢复场景依赖此判定。
  bool _engineLoaded = false;

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

  @override
  PlayerState build() {
    // dispose 回调内禁用 ref.read，提前捕获引擎仓库引用
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    ref.onDispose(() {
      _progressTimer?.cancel();
      _telemetryTimer?.cancel();
      _eventSub?.cancel();
      engineRepo.deinitEngine();
      _nativeAudio.dispose();
    });
    return const PlayerState();
  }

  void setBitPerfect(bool v) {
    state = state.copyWith(bitPerfect: v);
  }

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
      debugPrint('[Audio] 初始化原生音频失败: $e');
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

    _progressTimer?.cancel();
    state = state.copyWith(position: 0.0);

    // 立即静音当前声音（Rust 引擎 pause 保留输出流）：否则在解析/下载新歌
    // 期间旧歌继续响，切换才有延迟感；且切歌瞬间旧 ringbuf 被覆盖会爆音。
    await _engineRepo.pause();
    await _nativeAudio.stop();
    if (token != _playToken || !ref.mounted) return;

    // 解析本地可播放路径：SMB 远端先按需下载，HTTP 流式源先下载到本地缓存
    String? resolvedPath;
    if (song.smbPath != null && song.smbPath!.isNotEmpty) {
      resolvedPath = await SmbService.downloadToLocal(song.smbPath!);
    } else if (song.streamUrl != null && song.streamUrl!.isNotEmpty) {
      resolvedPath = await _downloadToCache(song.streamUrl!, song.id, song.title);
    } else {
      resolvedPath = await _resolvePlayablePath(song.path);
      // 校验本地文件存在性（避免 Subsonic server-local 路径被误判）
      if (resolvedPath != null && !await File(resolvedPath).exists()) {
        resolvedPath = null;
      }
    }
    if (token != _playToken || !ref.mounted) return;

    // 路径解析失败（SMB 下载失败/文件不存在/流式源不可用）→ 引擎没切歌，
    // 回滚 UI 到仍在播放的旧曲，避免"横条变了但音源没变"的错位。
    // 注意：上面已 pause 静音，回滚需 resume 恢复旧歌播放。
    if (resolvedPath == null) {
      debugPrint('[Audio] 无法播放 ${song.id}（resolvedPath=null），回滚到上一曲');
      ref.read(playErrorProvider.notifier).report(
        '无法播放「${song.title}」：文件不存在或下载失败',
      );
      if (fallbackSong != null) {
        state = state.copyWith(currentSong: fallbackSong);
        await _engineRepo.resume();
        saveResume();
      }
      return;
    }

    // 探测文件采样率（轻量头部读取）：供乐器面板显示信号链，并复用于 bit-perfect 协调。
    if (_engineRepo.rustAvailable) {
      _currentFileRate = await _engineRepo.probeSampleRate(resolvedPath);
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
      debugPrint('[Audio] engine play: $resolvedPath');
      await _engineRepo.play(resolvedPath);
    } else {
      debugPrint(
        '[Audio] engine play 跳过: rust=${_engineRepo.rustAvailable}',
      );
    }
    if (token != _playToken || !ref.mounted) return;

    if (token == _playToken) {
      state = state.copyWith(isPlaying: true);
      _startProgressTimer();
      await _nativeAudio.play(sampleRate: _nativeOutRate);
      _updateLockScreenMetadata();
      // 断点续播：锁屏进度锚点直接落在恢复位置
      _nativeAudio.updatePosition(initialSeekMs > 0 ? initialSeekMs : 0);
      _analyzeCurrent();
      _loadLyrics(resolvedPath);
      _engineLoaded = true;
      if (initialSeekMs > 0) {
        _seekToPosition(initialSeekMs);
      }
    }
  }

  void pause() {
    debugPrint('[Audio] Dart pause() 被调用');
    _progressTimer?.cancel();
    _engineRepo.pause();
    _nativeAudio.pause();
    // 事件驱动锚点：暂停时推当前位置，锁屏进度不再靠 250ms 轮询
    _nativeAudio.updatePosition(state.position);
    state = state.copyWith(isPlaying: false);
    saveResume();
  }

  void togglePlay() {
    if (state.currentSong == null) return;
    if (state.isPlaying) {
      pause();
    } else if (state.position > 0 && _engineLoaded) {
      // 暂停恢复播放（不从头开始）
      _startProgressTimer();
      _engineRepo.resume();
      _nativeAudio.resume();
      _nativeAudio.updatePosition(state.position);
      state = state.copyWith(isPlaying: true);
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

  /// 持久化断点：当前队列 + 索引 + 位置。供暂停/切歌/tick 兜底调用。
  void saveResume() {
    final q = ref.read(queueProvider);
    if (q.queue.isEmpty || state.currentSong == null) return;
    ref.read(preferencesRepositoryProvider).setResume(
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
      (state.position + 10000).clamp(0, song.duration.inMilliseconds.toDouble()),
    );
  }

  void skipBackward() {
    final song = state.currentSong;
    if (song == null) return;
    _seekToPosition(
      (state.position - 10000).clamp(0, song.duration.inMilliseconds.toDouble()),
    );
  }

  void _seekToPosition(double posMs) {
    final song = state.currentSong;
    if (song == null) return;
    final pos = posMs.clamp(0.0, song.duration.inMilliseconds.toDouble());
    state = state.copyWith(position: pos);
    if (!_nativeReady || !_engineRepo.rustAvailable) return;
    _engineRepo.seek(pos / 1000.0);
    // 原生侧清 AudioTrack/ringbuf 里 seek 前的旧 PCM，避免旧声音先播出造成错位。
    // iOS 无 seek 通道实现 → MissingPluginException 被 _safeCall 静默吞掉。
    _nativeAudio.seek(pos);
    // seek 后锁屏进度锚点必须立即更新（事件驱动，不再依赖 250ms 轮询）
    _nativeAudio.updatePosition(pos);
  }

  void setVolume(double v) {
    final volume = v.clamp(0.0, 1.0);
    state = state.copyWith(volume: volume);
    _engineRepo.setVolume(volume);
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
      debugPrint('[Audio] 遥测轮询失败: $e');
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

  Future<void> _tick() async {
    if (!state.isPlaying) return;
    try {
      final event = await _engineRepo.pollEvents();
      if (event != null) {
        debugPrint('[Audio] engine event: $event');
      }
      if (event == 'stopped') {
        debugPrint('[Audio] 收到引擎 stopped 事件 → 队列结束，触发切歌/停止');
        _progressTimer?.cancel();
        state = state.copyWith(isPlaying: false);
        onTrackEnd?.call();
        return;
      } else if (event == 'error') {
        final err = await _engineRepo.lastError();
        debugPrint('[Audio] 引擎错误: $err');
      }
    } catch (e) {
      debugPrint('[Audio] 事件轮询失败: $e');
    }

    // 引擎位置（ms）。查询失败时保留上次合法值，绝不盲目累加：
    // 锁屏后台 Dart Timer 被节流、FRB 通道抖动时 positionSecs 可能异常，
    // 原实现 _position += 250 会随轮询累积虚高，越过时长线被误判为曲终而自停。
    double? enginePosMs;
    try {
      enginePosMs = (await _engineRepo.positionSecs()) * 1000;
      state = state.copyWith(position: enginePosMs);
    } catch (e) {
      debugPrint('[Audio] 位置查询失败，保留上次位置: ${state.position.toInt()}ms');
    }

    final song = state.currentSong;
    // 曲终判断仅在引擎位置真实读取成功时进行，避免后台异常时误停。
    if (song != null &&
        enginePosMs != null &&
        enginePosMs >= song.duration.inMilliseconds) {
      debugPrint(
        '[Audio] 位置到达时长（${state.position.toInt()}ms >= '
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
    }
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
      debugPrint('[Audio] 分析音频失败: $e');
    }
  }

  /// 加载与音频文件同目录同名的 `.lrc` 歌词（大小写各试一次）。
  /// 无歌词时置 null；完成后 notify 以刷新歌词预览/全屏。
  Future<void> _loadLyrics(String? audioPath) async {
    List<LyricLine>? lyrics;
    if (audioPath != null && audioPath.isNotEmpty) {
      try {
        final base = audioPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
        for (final ext in const ['.lrc', '.LRC']) {
          final file = File('$base$ext');
          if (await file.exists()) {
            final parsed = parseLrc(await file.readAsString());
            if (parsed.isNotEmpty) {
              lyrics = parsed;
              break;
            }
          }
        }
      } catch (e) {
        debugPrint('[Audio] 歌词加载失败: $e');
      }
    }
    // 【临时】演示歌词：仅 debug 生效，预览歌词 UI 效果用，验收后删除
    if (kDebugMode && (lyrics == null || lyrics.isEmpty)) {
      lyrics = parseLrc(_demoLrc);
    }
    if (!ref.mounted) return;
    state = state.copyWith(lyrics: lyrics);
  }

  static const String _demoLrc = '''
[00:00.00]WaveLink 歌词演示
[00:06.00]这是一句演示歌词
[00:13.00]歌词会跟随播放进度逐行高亮
[00:20.00]点按预览行可以打开全屏歌词
[00:28.00]月光落在旧唱片的纹路里
[00:36.00]风声轻轻翻过昨日的和弦
[00:44.00]有些旋律不必说完
[00:52.00]有些故事听着就懂
[01:02.00]城市灯火一盏一盏熄灭
[01:10.00]只剩耳机里的世界还亮着
[01:18.00]把心事调成无损的格式
[01:26.00]每一个比特都不肯将就
[01:36.00]副歌来了 跟着节奏
[01:44.00]高音拉满 低音下潜
[01:52.00]这就是我们做播放器的理由
[02:02.00]让每一首歌都被认真播放
[02:12.00]让每一次聆听都不被辜负
[02:24.00]演示歌词即将结束
[02:36.00]感谢观看 ♪
[03:00.00]（之后的时间留白，验证最后一行常驻）
''';

  void _handleRemoteCommand(RemoteCommand cmd) {
    debugPrint('[Audio] 收到远程命令: ${cmd.command}');
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

  Future<String?> _downloadToCache(String url, String songId, String title) async {
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

      debugPrint('[Audio] 下载流式文件: $title');
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        debugPrint('[Audio] 下载失败 HTTP ${response.statusCode}');
        return null;
      }

      await cacheFile.writeAsBytes(response.bodyBytes);
      _streamCache[songId] = cacheFile.path;
      debugPrint('[Audio] 下载完成: ${cacheFile.path} (${response.bodyBytes.length} bytes)');
      return cacheFile.path;
    } catch (e) {
      debugPrint('[Audio] 流式下载失败: $e');
      return null;
    }
  }

  String _extFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '.audio';
    final path = uri.path.toLowerCase();
    for (final ext in ['.flac', '.wav', '.mp3', '.aac', '.ogg', '.m4a',
                       '.opus', '.dsf', '.dff', '.aiff', '.ape', '.wv']) {
      if (path.endsWith(ext)) return ext;
    }
    return '.audio';
  }

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
      debugPrint('[Audio] 缓存封面失败: $e');
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
