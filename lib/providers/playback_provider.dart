export '../models/playback_types.dart';

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/lyric_line.dart';
import '../models/playback_types.dart';
import '../services/native_audio_service.dart';
import '../services/rust_service.dart' as rs;
import '../services/preferences_service.dart';
import 'dsp_mixin.dart';
import 'library_mixin.dart';

class PlaybackProvider extends ChangeNotifier with DspMixin, LibraryMixin {
  final NativeAudioService _nativeAudio = NativeAudioService();
  StreamSubscription<AudioEvent>? _eventSub;
  Timer? _progressTimer;
  bool _nativeReady = false;

  List<Song> _queue = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  double _position = 0.0;
  LoopMode _loopMode = LoopMode.list;
  double _volume = 0.8;
  bool _shuffle = false;
  bool _replayGain = true;
  bool _dynamicColor = true;
  double _coverBlur = 0.7;

  /// 解码器启动钩子（默认走引擎；测试可替换以注入延迟/记录）
  Future<void> Function(Song) startDecoderHook = (_) async {};

  /// setQueue 后是否自动开始播放（默认 true；测试可置 false 避免副作用）
  bool autoPlayOnQueueSet = true;

  final Map<String, rs.AnalyzeResult> _analysisCache = {};

  PlaybackProvider() {
    _loadPreferences();
    _initNative();
    scanImported();
  }

  void _loadPreferences() {
    final prefs = PreferencesService.instance;
    _volume = prefs.volume;
    _shuffle = prefs.shuffle;
    _loopMode = LoopMode.values.firstWhere(
      (m) => m.name == prefs.loopMode,
      orElse: () => LoopMode.list,
    );
    _replayGain = prefs.replayGain;
    _dynamicColor = prefs.dynamicColor;
    _coverBlur = prefs.coverBlur;
    loadDspPrefs();
    loadFavoritesPrefs();
  }

  //── LibraryMixin 抽象方法实现 ──

  @override
  Song? currentSongForFav() => currentSong;

  @override
  List<Song> queueSongsForLib() => _queue;

  @override
  void onImportedSongsLoaded(List<Song> songs) {
    _queue = List.from(songs);
    _currentIndex = 0;
    batchExtractCovers(songs);
  }

  @override
  void onImportAdded(List<Song> songs) {
    _queue.addAll(songs);
    if (_queue.length == songs.length) _currentIndex = 0;
  }

  @override
  void onRescan(List<Song> songs) {
    for (final s in songs) {
      final idx = _queue.indexWhere((q) => q.path == s.path);
      if (idx >= 0) _queue[idx] = s;
    }
  }

  //── 分析缓存 ──

  rs.AnalyzeResult? getAnalysis(String songId) => _analysisCache[songId];

  Future<void> _analyzeCurrent() async {
    final song = currentSong;
    if (song == null || !rs.rustAvailable) return;
    if (_analysisCache.containsKey(song.id)) return;
    try {
      final result = await rs.analyzeAudioFile(song.path!);
      _analysisCache[song.id] = result;
      notifyListeners();
    } catch (e) {
      debugPrint('[Playback] 分析音频失败: $e');
    }
  }

  Future<void> _initNative() async {
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
        await applyDsp();
      }
    } catch (e) {
      debugPrint('[Playback] 初始化原生音频失败: $e');
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

  //── getters ──

  bool get hasSong => _queue.isNotEmpty;
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;
  double get position => _position;
  LoopMode get loopMode => _loopMode;
  List<Song> get queue => _queue;
  double get volume => _volume;
  bool get shuffle => _shuffle;
  bool get replayGain => _replayGain;
  bool get dynamicColor => _dynamicColor;
  double get coverBlur => _coverBlur;

  double get progress {
    final song = currentSong;
    if (song == null) return 0.0;
    return _position / song.duration.inMilliseconds;
  }

  List<LyricLine>? get currentLyrics => null;
  int get currentLyricLine => -1;

  //── transport ──

  void play() {
    if (!hasSong) return;
    _playCurrent();
  }

  void pause() {
    _isPlaying = false;
    _progressTimer?.cancel();
    rs.enginePause();
    _nativeAudio.pause();
    notifyListeners();
  }

  void togglePlay() {
    if (!hasSong) return;
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

  void next() {
    if (!hasSong) return;
    if (_loopMode == LoopMode.single) {
      rs.engineSeek(0);
      return;
    }
    if (_shuffle) {
      _currentIndex =
          (_currentIndex + 1 + _random.nextInt(_queue.length - 1)) %
          _queue.length;
    } else {
      _currentIndex = (_currentIndex + 1) % _queue.length;
    }
    _playCurrent();
  }

  void previous() {
    if (!hasSong) return;
    if (_position > 3000) {
      rs.engineSeek(0);
    } else {
      _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
      _playCurrent();
    }
  }

  int _playToken = 0;

  Future<void> _playCurrent() async {
    final song = currentSong;
    if (song == null) return;
    final token = ++_playToken;

    _progressTimer?.cancel();
    _position = 0;

    await _nativeAudio.stop();
    if (token != _playToken) return;

    if (song.path != null && rs.rustAvailable) {
      debugPrint('[Playback] engine play: ${song.title}');
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
        next();
        return;
      } else if (event == 'error') {
        final err = await rs.engineLastError();
        debugPrint('[Playback] 引擎错误: $err');
      }
    } catch (e) {
      debugPrint('[Playback] 事件轮询失败: $e');
    }

    try {
      final secs = await rs.enginePositionSecs();
      _position = secs * 1000;
    } catch (e) {
      _position += 250;
    }

    final song = currentSong;
    if (song != null && _position >= song.duration.inMilliseconds) {
      _progressTimer?.cancel();
      _isPlaying = false;
      notifyListeners();
      next();
      return;
    }

    _nativeAudio.updatePosition(_position);
    notifyListeners();
  }

  //── seek ──

  void seek(double value, {bool immediate = false}) {
    final song = currentSong;
    if (song == null) return;
    final posMs = value * song.duration.inMilliseconds;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();
    if (immediate) _seekToPosition(_position);
  }

  void _seekToPosition(double posMs) {
    final song = currentSong;
    if (song == null) return;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();
    if (!_nativeReady || !rs.rustAvailable) return;
    rs.engineSeek(_position / 1000.0);
  }

  void skipForward() {
    final song = currentSong;
    if (song == null) return;
    _seekToPosition(
      (_position + 10000).clamp(0, song.duration.inMilliseconds.toDouble()),
    );
  }

  void skipBackward() {
    final song = currentSong;
    if (song == null) return;
    _seekToPosition(
      (_position - 10000).clamp(0, song.duration.inMilliseconds.toDouble()),
    );
  }

  //── mode toggles ──

  void toggleLoopMode() {
    const modes = [LoopMode.list, LoopMode.single, LoopMode.shuffle];
    final idx = modes.indexOf(_loopMode);
    _loopMode = modes[(idx + 1) % modes.length];
    final modeCode = _loopMode == LoopMode.list ? 0
        : _loopMode == LoopMode.single ? 1 : 3;
    rs.engineSetPlayMode(mode: modeCode);
    PreferencesService.instance.setLoopMode(_loopMode.name);
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    PreferencesService.instance.setShuffle(_shuffle);
    notifyListeners();
  }

  void setVolume(double v) {
    _volume = v.clamp(0.0, 1.0);
    rs.engineSetVolume(vol: _volume);
    PreferencesService.instance.setVolume(_volume);
    notifyListeners();
  }

  //── playlist ──

  void playSong(Song song) {
    final idx = _queue.indexWhere((s) => s.id == song.id);
    if (idx >= 0) {
      _currentIndex = idx;
      _playCurrent();
    }
  }

  void playAlbum(List<Song> songs, {int startIndex = 0}) {
    _queue = List.from(songs);
    _currentIndex = startIndex.clamp(0, _queue.length - 1);
    _playCurrent();
  }

  void addToQueue(Song song) {
    _queue.add(song);
    notifyListeners();
  }

  void playNext(Song song) {
    _queue.insert(_currentIndex + 1, song);
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (index == _currentIndex) {
      next();
      _queue.removeAt(index);
      if (_currentIndex >= _queue.length) _currentIndex = 0;
    } else {
      if (index < _currentIndex) _currentIndex--;
      _queue.removeAt(index);
    }
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);
    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    notifyListeners();
  }

  void setQueue(List<Song> songs) {
    _queue = songs;
    _currentIndex = 0;
    if (_queue.isNotEmpty && autoPlayOnQueueSet) _playCurrent();
  }

  //── helpers ──

  static final _random = _SimpleRandom();

  int findNextIndex() {
    if (_queue.isEmpty) return 0;
    if (_shuffle) {
      return (_currentIndex + 1 + _random.nextInt(_queue.length - 1)) %
          _queue.length;
    }
    return (_currentIndex + 1) % _queue.length;
  }

  // ── 外观设置 ──

  void setReplayGain(bool v) {
    _replayGain = v;
    PreferencesService.instance.setReplayGain(v);
    notifyListeners();
  }

  void setDynamicColor(bool v) {
    _dynamicColor = v;
    PreferencesService.instance.setDynamicColor(v);
    notifyListeners();
  }

  void setCoverBlur(double v) {
    _coverBlur = v.clamp(0.0, 1.0);
    PreferencesService.instance.setCoverBlur(_coverBlur);
    notifyListeners();
  }

  // ── 锁屏控制 ──

  void _handleRemoteCommand(RemoteCommand cmd) {
    switch (cmd.command) {
      case 'play':
      case 'togglePlayPause':
        togglePlay();
      case 'pause':
        pause();
      case 'next':
        next();
      case 'previous':
        previous();
      case 'seek':
        if (cmd.seekPosition != null) {
          final song = currentSong;
          if (song != null) {
            final posMs = cmd.seekPosition! * 1000;
            seek(posMs / song.duration.inMilliseconds);
          }
        }
    }
  }

  Future<void> _updateLockScreenMetadata() async {
    if (!_nativeReady) return;
    final song = currentSong;
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
      debugPrint('[Playback] 缓存封面失败: $e');
    }
  }
}

class _SimpleRandom {
  int _seed = DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;

  int nextInt(int max) {
    if (max <= 0) return 0;
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed % max;
  }
}
