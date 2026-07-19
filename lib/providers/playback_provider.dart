import 'dart:async';
import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/lyric_line.dart';
import '../services/native_audio_service.dart';
import '../services/rust_service.dart' as rs;
import '../services/import_service.dart';
import '../services/preferences_service.dart';
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
  bool _replayGain = true;
  bool _dynamicColor = true;
  double _coverBlur = 0.7;

  //── DSP ──
  dsp.DspHandle? _dspHandle;
  DspSettings _dspSettings = DspSettings();

  /// 解码器启动钩子（默认走真实 Rust 解码；测试可替换以注入延迟/记录）
  Future<void> Function(Song) startDecoderHook = (_) async {};

  /// setQueue 后是否自动开始播放（默认 true；测试可置 false 避免副作用）
  bool autoPlayOnQueueSet = true;

  PlaybackProvider() {
    _loadPreferences();
    _initNative();
    _scanImported();
  }

  /// 从本地偏好恢复状态
  void _loadPreferences() {
    final prefs = PreferencesService.instance;
    _volume = prefs.volume;
    _shuffle = prefs.shuffle;
    _loopMode = LoopMode.values.firstWhere(
      (m) => m.name == prefs.loopMode,
      orElse: () => LoopMode.list,
    );
    _favoriteIds.addAll(prefs.favorites);
    _replayGain = prefs.replayGain;
    _dynamicColor = prefs.dynamicColor;
    _coverBlur = prefs.coverBlur;
    _dspSettings = DspSettings(
      enabled: prefs.dspEnabled,
      crossfeed: prefs.dspCrossfeed,
      widener: prefs.dspWidener,
      limiter: prefs.dspLimiter,
      dither: prefs.dspDither,
    );
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
    _seekThrottleTimer?.cancel();
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
  bool get replayGain => _replayGain;
  bool get dynamicColor => _dynamicColor;
  double get coverBlur => _coverBlur;
  /// 已知歌曲全集（导入歌曲 + 当前队列），用于收藏/播放列表的 id 查找
  List<Song> get _allKnownSongs {
    final ids = <String>{};
    final out = <Song>[];
    for (final s in [..._importedSongs, ..._queue]) {
      if (ids.add(s.id)) out.add(s);
    }
    return out;
  }

  List<Song> get favoriteSongs =>
      _allKnownSongs.where((s) => _favoriteIds.contains(s.id)).toList();

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

  /// 切歌 token：每次 _playCurrent 自增，旧的开播流程若发现 token 变化则放弃，
  /// 避免快速切歌时上一首的 play() 覆盖当前歌曲，造成数据错位/爆音。
  int _playToken = 0;

  Future<void> _playCurrent() async {
    final song = currentSong;
    if (song == null) return;
    final token = ++_playToken;

    _progressTimer?.cancel();
    _position = 0;

    // 1) 先真正暂停 sourceNode，避免实时线程在 ringbuf 重建窗口期拉到空/错位数据
    await _nativeAudio.stop();
    if (token != _playToken) return;

    // 2) 等 Rust 侧解码器真正停止并重启（await 真实 native future）
    await _playPcm(song);
    if (token != _playToken) return;

    if (token == _playToken) {
      _analyzeCurrent();
      startPlayback();
    }
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
    // 解码器重置完成后，钩子可触发后续（测试用它注入延迟/记录）
    await startDecoderHook(song);
  }

  /// 从 seek 位置重启 Rust 解码器
  Future<void> _restartStreamFrom(double posMs, String path, [int? token]) async {
    if (!_nativeReady || !rs.rustAvailable) return;
    final seekSecs = (posMs / 1000.0).clamp(0.0, double.infinity);
    debugPrint('[Seek] restart decoder at ${seekSecs}s');

    // 注意：不能调用 _nativeAudio.pause() 再 play()。
    // AVAudioEngine.pause()/start() 在 AVAudioSourceNode 上会导致渲染时钟跳变，
    // resume 时重复/错位最后缓冲帧 = 拖动进度时的"磁带滑"。
    // 这里依赖 Rust stopDecoder 内部的 clear_ringbuf 清空 ringbuf，
    // sourceNode 在 engine 持续运行期间只会拉到静音（空 ringbuf），
    // 再由 startDecoder 推入新帧，过渡干净无跳变。
    await rs.stopDecoder();
    // 防重入：若期间又来了新的 seek（token 变化），放弃本次耗时解码，
    // 避免旧解码覆盖新位置导致卡顿/错位。
    if (token != null && token != _seekToken) return;
    await rs.startDecoder(path, seekSecs: seekSecs);
    if (token != null && token != _seekToken) return;
    // 仅当原本就在播放时才恢复输出。play() 幂等：engine 已运行时不会再次
    // engine.start()，避免 AVAudioSourceNode 的 resume 时钟跳变（磁带滑）。
    // 若原本处于暂停态（如用户主动暂停后拖动进度），保持暂停静音，
    // 不触发 engine.start()，因此也不会产生跳变。
    if (_isPlaying) {
      _nativeAudio.play();
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

  /// 拖动进度条时的连续回调：节流执行，避免快速滑动触发 seek 风暴
  /// （m4a 等格式的 format.seek 较重，叠加会拖垮解码线程导致卡顿）。
  Timer? _seekThrottleTimer;
  double? _pendingSeekMs;

  void seek(double value, {bool immediate = false}) {
    final song = currentSong;
    if (song == null) return;
    final posMs = value * song.duration.inMilliseconds;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();

    if (immediate) {
      // 拖动结束：取消节流，立即精确 seek 到落点
      _seekThrottleTimer?.cancel();
      _pendingSeekMs = null;
      _seekToPosition(_position);
      return;
    }
    // 拖动中节流：最多每 160ms 真正 seek 一次（略大于 m4a 单次 seek 耗时
    // ~140ms，保证每次 seek 都能产出数据再被下一次覆盖），且始终使用最新目标。
    _pendingSeekMs = _position;
    _seekThrottleTimer?.cancel();
    _seekThrottleTimer = Timer(const Duration(milliseconds: 160), () {
      final target = _pendingSeekMs;
      _pendingSeekMs = null;
      if (target != null) _seekToPosition(target);
    });
  }

  /// 切歌 token：每次 seek 自增，旧的重启流程若发现 token 变化则放弃，
  /// 避免快速连续 seek 时上一次耗时的解码覆盖当前位置，造成卡顿/错位。
  int _seekToken = 0;

  void _seekToPosition(double posMs) {
    final song = currentSong;
    if (song == null) return;
    final token = ++_seekToken;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();

    if (!_nativeReady || !rs.rustAvailable) return;
    _restartStreamFrom(posMs, song.path!, token);
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
    PreferencesService.instance.setVolume(_volume);
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
    _persistFavorites();
    notifyListeners();
  }

  /// 直接设置某首歌曲的收藏状态（供列表长按等场景使用）
  void setFavorite(String songId, bool favorite) {
    if (favorite) {
      _favoriteIds.add(songId);
    } else {
      _favoriteIds.remove(songId);
    }
    _persistFavorites();
    notifyListeners();
  }

  void _persistFavorites() {
    PreferencesService.instance.setFavorites(_favoriteIds);
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
    if (_queue.isNotEmpty && autoPlayOnQueueSet) _playCurrent();
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
    PreferencesService.instance.setDspEnabled(_dspSettings.enabled);
    _applyDsp();
    notifyListeners();
  }

  void toggleCrossfeed() {
    _dspSettings = _dspSettings.copyWith(crossfeed: !_dspSettings.crossfeed);
    PreferencesService.instance.setDspCrossfeed(_dspSettings.crossfeed);
    _applyDsp();
    notifyListeners();
  }

  void toggleWidener() {
    _dspSettings = _dspSettings.copyWith(widener: !_dspSettings.widener);
    PreferencesService.instance.setDspWidener(_dspSettings.widener);
    _applyDsp();
    notifyListeners();
  }

  void toggleLimiter() {
    _dspSettings = _dspSettings.copyWith(limiter: !_dspSettings.limiter);
    PreferencesService.instance.setDspLimiter(_dspSettings.limiter);
    _applyDsp();
    notifyListeners();
  }

  void toggleDither() {
    _dspSettings = _dspSettings.copyWith(dither: !_dspSettings.dither);
    PreferencesService.instance.setDspDither(_dspSettings.dither);
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
      // limiter / dither 在 Rust DspPipeline 中随 process 常驻，
      // 这里仅持久化开关状态（见 DspSettings），后续可在 Rust 端加 set 接口。
    } catch (_) {}
  }

  // ── 外观 / 增益设置（持久化）──

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

  // ── 播放列表（按歌曲 id 集合持久化）──

  Map<String, List<String>> get playlists => PreferencesService.instance.playlists;

  /// 保存当前队列为播放列表
  Future<void> saveCurrentQueueAsPlaylist(String name) async {
    final ids = _queue.map((s) => s.id).toList();
    await PreferencesService.instance.savePlaylist(name, ids);
    notifyListeners();
  }

  /// 覆盖保存某个播放列表（按歌曲 id）
  Future<void> savePlaylist(String name, List<String> songIds) async {
    await PreferencesService.instance.savePlaylist(name, songIds);
    notifyListeners();
  }

  /// 用已保存的播放列表 id 还原出 Song 列表
  List<Song> playlistSongs(String name) {
    final ids = playlists[name] ?? [];
    final byId = {for (final s in _allKnownSongs) s.id: s};
    return ids.where((id) => byId.containsKey(id)).map((id) => byId[id]!).toList();
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
