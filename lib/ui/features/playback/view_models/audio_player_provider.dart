import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../../../../domain/models/song.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../../data/services/native_audio_service.dart';
import '../../../../data/services/lrc_parser.dart';
import '../../../../data/repositories/audio_engine_repository.dart';
import '../../../../data/services/rust_service.dart' show AnalyzeResult;

class AudioPlayerProvider extends ChangeNotifier {
  AudioPlayerProvider({required this._engineRepo});

  final AudioEngineRepository _engineRepo;
  final NativeAudioService _nativeAudio = NativeAudioService();
  StreamSubscription<AudioEvent>? _eventSub;
  Timer? _progressTimer;
  bool _nativeReady = false;

  bool _isPlaying = false;
  double _position = 0.0;
  double _volume = 0.8;
  int _playToken = 0;

  // ── 引擎遥测（乐器面板）──
  Timer? _telemetryTimer;
  int _lastUnderrun = 0;
  int _currentFileRate = 0;

  /// Android 设备原生输出采样率（初始化时查询，默认 44100）。
  /// 引擎产出速率与 AudioTrack 速率都用它，消掉强制 44.1k 双重重采样。
  int _nativeOutRate = 44100;
  EngineTelemetry _telemetry = EngineTelemetry.idle;

  /// 当前曲目的歌词（无歌词时为 null）
  List<LyricLine>? _lyrics;

  /// 引擎实时遥测（采样率/underrun/播放状态）
  EngineTelemetry get telemetry => _telemetry;

  /// bit-perfect / 采样率跟随（由 PlaybackProvider 从偏好同步）。
  /// 开启后切歌时把输出速率对齐到文件速率（iOS 经 AVAudioSession），相等时不重采样。
  bool bitPerfect = false;

  Future<void> Function(Song) startDecoderHook = (_) async {};
  VoidCallback? onTrackEnd;
  VoidCallback? onNext;
  VoidCallback? onPrevious;

  Song? _currentSong;
  void setCurrentSong(Song? song) => _currentSong = song;

  bool get isPlaying => _isPlaying;
  double get position => _position;
  double get volume => _volume;
  Song? get currentSong => _currentSong;
  AudioEngineRepository get engineRepo => _engineRepo;

  double get progress {
    final song = _currentSong;
    if (song == null) return 0.0;
    return _position / song.duration.inMilliseconds;
  }

  List<LyricLine>? get currentLyrics => _lyrics;
  int get currentLyricLine {
    final lyrics = _lyrics;
    if (lyrics == null || lyrics.isEmpty) return -1;
    final pos = _position; // ms
    int idx = -1;
    for (int i = 0; i < lyrics.length; i++) {
      if (lyrics[i].timeMs <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
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

  @override
  void dispose() {
    _progressTimer?.cancel();
    _telemetryTimer?.cancel();
    _eventSub?.cancel();
    _engineRepo.deinitEngine();
    _nativeAudio.dispose();
    super.dispose();
  }

  void play() {
    if (_currentSong == null) return;
    if (_position > 0 && !_isPlaying) {
      // 恢复播放（不从头开始）
      togglePlay();
    } else {
      _playCurrent();
    }
  }

  void playSong(Song song) {
    _currentSong = song;
    _position = 0;
    _playCurrent();
  }

  Future<void> _playCurrent() async {
    final song = _currentSong;
    if (song == null) return;
    final token = ++_playToken;

    _progressTimer?.cancel();
    _position = 0;

    await _nativeAudio.stop();
    if (token != _playToken) return;

    // 解析本地可播放路径：远程流式源先下载到本地缓存
    String? resolvedPath;
    if (song.streamUrl != null && song.streamUrl!.isNotEmpty) {
      resolvedPath = await _downloadToCache(song.streamUrl!, song.id, song.title);
    } else {
      resolvedPath = await _resolvePlayablePath(song.path);
      // 校验本地文件存在性（避免 Subsonic server-local 路径被误判）
      if (resolvedPath != null && !await File(resolvedPath).exists()) {
        resolvedPath = null;
      }
    }
    if (token != _playToken) return;

    // 探测文件采样率（轻量头部读取）：供乐器面板显示信号链，并复用于 bit-perfect 协调。
    if (resolvedPath != null && _engineRepo.rustAvailable) {
      _currentFileRate = await _engineRepo.probeSampleRate(resolvedPath);
      if (token != _playToken) return;
    } else {
      _currentFileRate = 0;
    }

    // bit-perfect 协调：iOS 设 AVAudioSession 读回实际速率 → 引擎设输出速率。
    // 实际速率 == 文件速率时解码器不重采样（bit-perfect）；iOS 未满足时引擎按实际速率重采样保证播放正确。
    if (bitPerfect && _currentFileRate > 0) {
      final actualRate = await _nativeAudio.setOutputRate(
        _currentFileRate.toDouble(),
      );
      if (token != _playToken) return;
      if (actualRate > 0) {
        await _engineRepo.setOutputSampleRate(actualRate.round());
      }
    }

    if (resolvedPath != null && _engineRepo.rustAvailable) {
      debugPrint('[Audio] engine play: $resolvedPath');
      await _engineRepo.play(resolvedPath);
    } else {
      debugPrint('[Audio] engine play 跳过: resolvedPath=$resolvedPath rust=${_engineRepo.rustAvailable}');
    }
    if (token != _playToken) return;

    if (token == _playToken) {
      _isPlaying = true;
      _startProgressTimer();
      await _nativeAudio.play(sampleRate: _nativeOutRate);
      _updateLockScreenMetadata();
      _analyzeCurrent();
      _loadLyrics(resolvedPath);
      notifyListeners();
    }
  }

  void pause() {
    debugPrint('[Audio] Dart pause() 被调用');
    _isPlaying = false;
    _progressTimer?.cancel();
    _engineRepo.pause();
    _nativeAudio.pause();
    notifyListeners();
  }

  void togglePlay() {
    if (_currentSong == null) return;
    if (_isPlaying) {
      pause();
    } else {
      _isPlaying = true;
      _startProgressTimer();
      _engineRepo.resume();
      _nativeAudio.resume();
      notifyListeners();
    }
  }

  void startPlayback() {
    _isPlaying = true;
    _startProgressTimer();
    _nativeAudio.play(sampleRate: _nativeOutRate);
    _updateLockScreenMetadata();
    notifyListeners();
  }

  void seek(double value, {bool immediate = false}) {
    final song = _currentSong;
    if (song == null) return;
    final posMs = value * song.duration.inMilliseconds;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();
    if (immediate) _seekToPosition(_position);
  }

  void seekToStart() {
    _seekToPosition(0);
  }

  void skipForward() {
    final song = _currentSong;
    if (song == null) return;
    _seekToPosition(
      (_position + 10000).clamp(0, song.duration.inMilliseconds.toDouble()),
    );
  }

  void skipBackward() {
    final song = _currentSong;
    if (song == null) return;
    _seekToPosition(
      (_position - 10000).clamp(0, song.duration.inMilliseconds.toDouble()),
    );
  }

  void _seekToPosition(double posMs) {
    final song = _currentSong;
    if (song == null) return;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();
    if (!_nativeReady || !_engineRepo.rustAvailable) return;
    _engineRepo.seek(_position / 1000.0);
    // 原生侧清 AudioTrack/ringbuf 里 seek 前的旧 PCM，避免旧声音先播出造成错位。
    // iOS 无 seek 通道实现 → MissingPluginException 被 _safeCall 静默吞掉。
    _nativeAudio.seek(_position);
  }

  void setVolume(double v) {
    _volume = v.clamp(0.0, 1.0);
    _engineRepo.setVolume(_volume);
    notifyListeners();
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
    if (!_isPlaying) {
      _telemetryTimer?.cancel();
      _telemetryTimer = null;
      if (_currentSong == null) {
        // 无曲目：清为 idle
        if (_telemetry.running || _telemetry.underrunRecent != 0) {
          _telemetry = EngineTelemetry.idle;
          notifyListeners();
        }
      } else if (_telemetry.running) {
        // 曲目暂停：保留信号链展示（速率/underrun 统计——暂停时正是用户
        // 看面板的时候），只翻停止态，不清空
        _telemetry = EngineTelemetry(
          outputRate: _telemetry.outputRate,
          fileRate: _telemetry.fileRate,
          underrunTotal: _telemetry.underrunTotal,
          underrunRecent: _telemetry.underrunRecent,
          running: false,
          bufferMs: _telemetry.bufferMs,
        );
        notifyListeners();
      }
      return;
    }
    if (!_engineRepo.rustAvailable) return;

    try {
      final results = await Future.wait([
        _engineRepo.getHwSampleRate(),
        _engineRepo.getUnderrunCount(),
      ]);
      final outputRate = results[0];
      final underrunTotal = results[1];
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
      );

      // 仅在读数变化时 notify，避免无谓重建
      if (_telemetryChanged(next)) {
        _telemetry = next;
        notifyListeners();
      } else {
        _telemetry = next;
      }
    } catch (e) {
      debugPrint('[Audio] 遥测轮询失败: $e');
    }
  }

  bool _telemetryChanged(EngineTelemetry n) {
    final o = _telemetry;
    return n.outputRate != o.outputRate ||
        n.fileRate != o.fileRate ||
        n.underrunTotal != o.underrunTotal ||
        n.underrunRecent != o.underrunRecent ||
        n.running != o.running;
  }

  Future<void> _tick() async {
    if (!_isPlaying) return;
    try {
      final event = await _engineRepo.pollEvents();
      if (event != null) {
        debugPrint('[Audio] engine event: $event');
      }
      if (event == 'stopped') {
        debugPrint('[Audio] 收到引擎 stopped 事件 → 队列结束，触发切歌/停止');
        _progressTimer?.cancel();
        _isPlaying = false;
        notifyListeners();
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
      _position = enginePosMs;
    } catch (e) {
      debugPrint('[Audio] 位置查询失败，保留上次位置: ${_position.toInt()}ms');
    }

    final song = _currentSong;
    // 曲终判断仅在引擎位置真实读取成功时进行，避免后台异常时误停。
    if (song != null &&
        enginePosMs != null &&
        enginePosMs >= song.duration.inMilliseconds) {
      debugPrint(
        '[Audio] 位置到达时长（${_position.toInt()}ms >= '
        '${song.duration.inMilliseconds}ms）→ 视为曲终',
      );
      _progressTimer?.cancel();
      _isPlaying = false;
      notifyListeners();
      onTrackEnd?.call();
      return;
    }

    _nativeAudio.updatePosition(_position);
    notifyListeners();
  }

  Future<void> _analyzeCurrent() async {
    final song = _currentSong;
    if (song == null || !_engineRepo.rustAvailable) return;
    if (_engineRepo.hasAnalysis(song.id)) return;
    try {
      await _engineRepo.analyzeFile(song.id, song.path!);
      notifyListeners();
    } catch (e) {
      debugPrint('[Audio] 分析音频失败: $e');
    }
  }

  /// 加载与音频文件同目录同名的 `.lrc` 歌词（大小写各试一次）。
  /// 无歌词时置 null；完成后 notify 以刷新歌词预览/全屏。
  Future<void> _loadLyrics(String? audioPath) async {
    _lyrics = null;
    if (audioPath == null || audioPath.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      final base = audioPath.replaceFirst(RegExp(r'\.[^.]+$'), '');
      for (final ext in const ['.lrc', '.LRC']) {
        final file = File('$base$ext');
        if (await file.exists()) {
          final parsed = parseLrc(await file.readAsString());
          if (parsed.isNotEmpty) {
            _lyrics = parsed;
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('[Audio] 歌词加载失败: $e');
    }
    // 【临时】演示歌词：仅 debug 生效，预览歌词 UI 效果用，验收后删除
    if (kDebugMode && (_lyrics == null || _lyrics!.isEmpty)) {
      _lyrics = parseLrc(_demoLrc);
    }
    notifyListeners();
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
    final song = _currentSong;
    if (song == null) return;
    await _ensureCoverCached(song);
    await _nativeAudio.updateMetadata(
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration.inMilliseconds / 1000.0,
      filePath: song.path,
    );
  }

  Future<void> _ensureCoverCached(Song song) async {
    if (!song.hasCover || song.path == null) return;
    if (song.coverUrl != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheFile = File('${appDir.path}/.covers/${song.path!.hashCode}.jpg');
    if (await cacheFile.exists()) {
      song.coverUrl = cacheFile.path;
      notifyListeners();
      return;
    }
    try {
      final bytes = await _engineRepo.getCoverBytes(song.path!);
      final cacheDir = Directory('${appDir.path}/.covers');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      await cacheFile.writeAsBytes(bytes);
      song.coverUrl = cacheFile.path;
      notifyListeners();
    } catch (e) {
      debugPrint('[Audio] 缓存封面失败: $e');
    }
  }
}
