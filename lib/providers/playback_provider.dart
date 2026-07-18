import 'dart:async';
import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/lyric_line.dart';
import '../services/native_audio_service.dart';
import '../services/rust_service.dart' as rs;
import '../services/import_service.dart';
import '../src/rust/api/dsp.dart' as dsp;

class PlaybackProvider extends ChangeNotifier {
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
  final Set<String> _favoriteIds = {};
  bool _shuffle = false;
  List<Song> _importedSongs = [];
  bool _scanDone = false;

  //── DSP ──
  dsp.DspHandle? _dspHandle;
  DspSettings _dspSettings = DspSettings();

  PlaybackProvider() {
    _initNative();
    _scanImported();
  }

  Future<void> _scanImported() async {
    final songs = await ImportService.scanDocuments();
    if (songs.isNotEmpty) {
      _importedSongs = songs;
      _queue = List.from(songs);
      _currentIndex = 0;
    }
    _scanDone = true;
    notifyListeners();
  }

  Future<void> _initNative() async {
    try {
      await _nativeAudio.init();
      _nativeReady = true;
      _eventSub = _nativeAudio.events.listen((event) {
        if (event is AudioCompleted) {
          _progressTimer?.cancel();
          _position = 0;
          next();
        }
      });
      if (rs.rustAvailable) {
        await rs.initRingbuf();
        _dspHandle = await dsp.createDsp(
          sampleRate: 44100,
          channels: 2,
          volume: _volume,
          bits: 24,
        );
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _eventSub?.cancel();
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
  bool get scanDone => _scanDone;
  List<Song> get importedSongs => _importedSongs;
  List<Song> get allSongs => _importedSongs;

  double get progress {
    final song = currentSong;
    if (song == null) return 0.0;
    return _position / song.duration.inMilliseconds;
  }

  bool get isFavorite {
    final song = currentSong;
    return song != null && _favoriteIds.contains(song.id);
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
      _nativeAudio.resume();
      notifyListeners();
    }
  }

  /// 是否需要开始播放（首次播放或恢复）
  void startPlayback() {
    _isPlaying = true;
    _startProgressTimer();
    _nativeAudio.play();
    notifyListeners();
  }

  void next() {
    if (!hasSong) return;
    if (_loopMode == LoopMode.single) {
      _seekToPosition(0);
      _playCurrent();
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
      _seekToPosition(0);
    } else {
      _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
      _playCurrent();
    }
  }

  void _playCurrent() {
    final song = currentSong;
    if (song == null) return;

    _progressTimer?.cancel();
    _nativeAudio.stop();
    _position = 0;

    if (_nativeReady) _playPcm(song);

    _analyzeCurrent();

    startPlayback();
  }

  /// 启动 Rust 后台解码线程，直接推 ringbuf
  Future<void> _playPcm(Song song) async {
    if (song.path != null && rs.rustAvailable) {
      debugPrint('[Playback] start Rust decoder for ${song.title}');
      await rs.stopDecoder();
      await rs.startDecoder(song.path!, seekSecs: null);
    } else {
      debugPrint('[Playback] no path or rust, skipping play');
    }
  }

  /// 从 seek 位置重启 Rust 解码器
  Future<void> _restartStreamFrom(double posMs, String path) async {
    if (!_nativeReady || !rs.rustAvailable) return;
    final seekSecs = (posMs / 1000.0).clamp(0.0, double.infinity);
    debugPrint('[Seek] restart decoder at ${seekSecs}s');

    await rs.stopDecoder();
    await rs.startDecoder(path, seekSecs: seekSecs);
    _nativeAudio.play();
    if (!_isPlaying) {
      _isPlaying = true;
      _startProgressTimer();
      notifyListeners();
    }
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_isPlaying) return;
      final song = currentSong;
      if (song == null) return;
      _position += 250;
      if (_position >= song.duration.inMilliseconds) {
        _position = song.duration.inMilliseconds.toDouble();
        _progressTimer?.cancel();
        // 通知 iOS 停止
        _nativeAudio.stop();
        // 触发下一首
        next();
      }
      notifyListeners();
    });
  }

  //── seek ──

  void seek(double value) {
    final song = currentSong;
    if (song == null) return;
    final posMs = value * song.duration.inMilliseconds;
    _seekToPosition(posMs);
  }

  void _seekToPosition(double posMs) {
    final song = currentSong;
    if (song == null) return;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();

    if (!_nativeReady || !rs.rustAvailable) return;
    _restartStreamFrom(posMs, song.path!);
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
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  void setVolume(double v) {
    _volume = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  //── favorites ──

  void toggleFavorite() {
    final song = currentSong;
    if (song == null) return;
    final id = song.id;
    if (_favoriteIds.contains(id)) {
      _favoriteIds.remove(id);
    } else {
      _favoriteIds.add(id);
    }
    notifyListeners();
  }

  bool isSongFavorite(String songId) => _favoriteIds.contains(songId);

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
    if (_queue.isNotEmpty) _playCurrent();
  }

  //── imported songs ──

  Future<int> importFromPicker() async {
    final songs = await ImportService.pickAndImport();
    if (songs.isEmpty) return 0;
    _importedSongs = [..._importedSongs, ...songs];
    _queue.addAll(songs);
    if (_queue.length == songs.length) _currentIndex = 0;
    notifyListeners();
    return songs.length;
  }

  //── rescan ──

  Future<void> rescanImported() async {
    final songs = await ImportService.scanDocuments();
    _importedSongs = songs;
    // 更新 queue 中已存在的歌曲元数据
    for (final s in songs) {
      final idx = _queue.indexWhere((q) => q.path == s.path);
      if (idx >= 0) _queue[idx] = s;
    }
    notifyListeners();
  }

  //── analysis cache ──

  final Map<String, rs.AnalyzeResult> _analysisCache = {};

  rs.AnalyzeResult? getAnalysis(String songId) => _analysisCache[songId];

  Future<void> _analyzeCurrent() async {
    final song = currentSong;
    if (song == null || !rs.rustAvailable) return;
    if (_analysisCache.containsKey(song.id)) return;
    try {
      final result = await rs.analyzeAudioFile(song.path!);
      _analysisCache[song.id] = result;
      notifyListeners();
    } catch (_) {}
  }

  //── DSP ──

  DspSettings get dspSettings => _dspSettings;
  bool get dspAvailable => _dspHandle != null;

  void toggleDspEnabled() {
    _dspSettings = _dspSettings.copyWith(enabled: !_dspSettings.enabled);
    notifyListeners();
  }

  void toggleCrossfeed() {
    _dspSettings = _dspSettings.copyWith(crossfeed: !_dspSettings.crossfeed);
    _applyDsp();
    notifyListeners();
  }

  void toggleWidener() {
    _dspSettings = _dspSettings.copyWith(widener: !_dspSettings.widener);
    _applyDsp();
    notifyListeners();
  }

  void toggleLimiter() {
    _dspSettings = _dspSettings.copyWith(limiter: !_dspSettings.limiter);
    _applyDsp();
    notifyListeners();
  }

  void toggleDither() {
    _dspSettings = _dspSettings.copyWith(dither: !_dspSettings.dither);
    _applyDsp();
    notifyListeners();
  }

  Future<void> _applyDsp() async {
    final handle = _dspHandle;
    if (handle == null) return;
    try {
      await dsp.dspSetCrossfeed(
        handle: handle,
        enabled: _dspSettings.crossfeed,
      );
      await dsp.dspSetStereoWidener(
        handle: handle,
        enabled: _dspSettings.widener,
        width: 0.5,
      );
    } catch (_) {}
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
}

enum LoopMode { list, single, shuffle }

class DspSettings {
  final bool enabled;
  final bool crossfeed;
  final bool widener;
  final bool limiter;
  final bool dither;

  const DspSettings({
    this.enabled = false,
    this.crossfeed = false,
    this.widener = false,
    this.limiter = false,
    this.dither = false,
  });

  DspSettings copyWith({
    bool? enabled,
    bool? crossfeed,
    bool? widener,
    bool? limiter,
    bool? dither,
  }) =>
      DspSettings(
        enabled: enabled ?? this.enabled,
        crossfeed: crossfeed ?? this.crossfeed,
        widener: widener ?? this.widener,
        limiter: limiter ?? this.limiter,
        dither: dither ?? this.dither,
      );
}

class _SimpleRandom {
  int _seed = DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;

  int nextInt(int max) {
    if (max <= 0) return 0;
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed % max;
  }
}
