import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../domain/models/song.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../data/services/native_audio_service.dart';
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

  /// bit-perfect / 采样率跟随（由 PlaybackProvider 从偏好同步）。
  /// 开启后切歌时把输出速率对齐到文件速率（iOS 经 AVAudioSession），相等时不重采样。
  bool bitPerfect = false;

  Future<void> Function(Song) startDecoderHook = (_) async {};
  VoidCallback? onTrackEnd;

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

  List<LyricLine>? get currentLyrics => null;
  int get currentLyricLine => -1;

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
        await _engineRepo.initEngine();
      }
    } catch (e) {
      debugPrint('[Audio] 初始化原生音频失败: $e');
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
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

    // bit-perfect 协调：探测文件速率 → iOS 设 AVAudioSession 读回实际速率 → 引擎设输出速率。
    // 实际速率 == 文件速率时解码器不重采样（bit-perfect）；iOS 未满足时引擎按实际速率重采样保证播放正确。
    if (bitPerfect && song.path != null && _engineRepo.rustAvailable) {
      final fileRate = await _engineRepo.probeSampleRate(song.path!);
      if (token != _playToken) return;
      if (fileRate > 0) {
        final actualRate = await _nativeAudio.setOutputRate(
          fileRate.toDouble(),
        );
        if (token != _playToken) return;
        if (actualRate > 0) {
          await _engineRepo.setOutputSampleRate(actualRate.round());
        }
      }
    }

    if (song.path != null && _engineRepo.rustAvailable) {
      await _engineRepo.play(song.path!);
    }
    if (token != _playToken) return;

    if (token == _playToken) {
      _isPlaying = true;
      _startProgressTimer();
      _nativeAudio.play();
      _updateLockScreenMetadata();
      _analyzeCurrent();
      notifyListeners();
    }
  }

  void pause() {
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
    _nativeAudio.play();
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
  }

  Future<void> _tick() async {
    if (!_isPlaying) return;
    try {
      final event = await _engineRepo.pollEvents();
      if (event == 'stopped') {
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

    try {
      final secs = await _engineRepo.positionSecs();
      _position = secs * 1000;
    } catch (e) {
      _position += 250;
    }

    final song = _currentSong;
    if (song != null && _position >= song.duration.inMilliseconds) {
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

  void _handleRemoteCommand(RemoteCommand cmd) {
    switch (cmd.command) {
      case 'play':
      case 'togglePlayPause':
        togglePlay();
      case 'pause':
        pause();
      case 'next':
      case 'previous':
      case 'seek':
        break;
    }
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
