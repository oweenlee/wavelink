import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/lyric_line.dart';
import '../services/native_audio_service.dart';
import '../services/rust_service.dart' as rs;

class AudioPlayerProvider extends ChangeNotifier {
  final NativeAudioService _nativeAudio = NativeAudioService();
  StreamSubscription<AudioEvent>? _eventSub;
  Timer? _progressTimer;
  bool _nativeReady = false;

  bool _isPlaying = false;
  double _position = 0.0;
  double _volume = 0.8;
  int _playToken = 0;
  final Map<String, rs.AnalyzeResult> _analysisCache = {};

  Future<void> Function(Song) startDecoderHook = (_) async {};
  VoidCallback? onTrackEnd;

  Song? _currentSong;
  void setCurrentSong(Song? song) => _currentSong = song;

  // ── getters ──

  bool get isPlaying => _isPlaying;
  double get position => _position;
  double get volume => _volume;
  Song? get currentSong => _currentSong;

  double get progress {
    final song = _currentSong;
    if (song == null) return 0.0;
    return _position / song.duration.inMilliseconds;
  }

  List<LyricLine>? get currentLyrics => null;
  int get currentLyricLine => -1;

  rs.AnalyzeResult? getAnalysis(String songId) => _analysisCache[songId];

  // ── 生命周期 ──

  Future<void> init() async {
    try {
      await _nativeAudio.init();
      _nativeReady = true;
      _eventSub = _nativeAudio.events.listen((event) {
        if (event is RemoteCommand) {
          _handleRemoteCommand(event);
        }
      });
      if (rs.rustAvailable) {
        await rs.initEngine();
      }
    } catch (e) {
      debugPrint('[Audio] 初始化原生音频失败: $e');
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _eventSub?.cancel();
    rs.deinitEngine();
    _nativeAudio.dispose();
    super.dispose();
  }

  // ── 播放控制 ──

  void play() {
    if (_currentSong == null) return;
    _playCurrent();
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

    if (song.path != null && rs.rustAvailable) {
      await rs.enginePlay(song.path!);
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
    rs.enginePause();
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
      rs.engineResume();
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

  // ── seek ──

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
    if (!_nativeReady || !rs.rustAvailable) return;
    rs.engineSeek(_position / 1000.0);
  }

  // ── 音量 ──

  void setVolume(double v) {
    _volume = v.clamp(0.0, 1.0);
    rs.engineSetVolume(vol: _volume);
    notifyListeners();
  }

  // ── 进度 ──

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tick();
    });
  }

  Future<void> _tick() async {
    if (!_isPlaying) return;
    try {
      final event = await rs.enginePollEvents();
      if (event == 'stopped') {
        _progressTimer?.cancel();
        _isPlaying = false;
        notifyListeners();
        onTrackEnd?.call();
        return;
      } else if (event == 'error') {
        final err = await rs.engineLastError();
        debugPrint('[Audio] 引擎错误: $err');
      }
    } catch (e) {
      debugPrint('[Audio] 事件轮询失败: $e');
    }

    try {
      final secs = await rs.enginePositionSecs();
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

  // ── 分析缓存 ──

  Future<void> _analyzeCurrent() async {
    final song = _currentSong;
    if (song == null || !rs.rustAvailable) return;
    if (_analysisCache.containsKey(song.id)) return;
    try {
      final result = await rs.analyzeAudioFile(song.path!);
      _analysisCache[song.id] = result;
      notifyListeners();
    } catch (e) {
      debugPrint('[Audio] 分析音频失败: $e');
    }
  }

  // ── 锁屏 ──

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
      final bytes = await rs.getCoverBytes(song.path!);
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
