import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/lyric_line.dart';
import '../services/native_audio_service.dart';
import '../services/rust_service.dart' as rs;
import '../services/import_service.dart';
import '../services/preferences_service.dart';
import '../src/rust/api/dsp.dart' as dsp;
import '../src/rust/api/audio_output.dart' as audio_out;
import '../src/rust/api/dsp.dart' show EqPreset;

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
      // 批量提取缺失的封面
      _batchExtractCovers(songs);
    }
    _scanDone = true;
    notifyListeners();
  }

  /// 后台批量提取缺失封面
  Future<void> _batchExtractCovers(List<Song> songs) async {
    if (!rs.rustAvailable) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/.covers');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

    var changed = false;
    for (final song in songs) {
      if (!song.hasCover || song.path == null || song.coverUrl != null) continue;
      final cacheFile = File('${cacheDir.path}/${song.path!.hashCode}.jpg');
      if (await cacheFile.exists()) {
        song.coverUrl = cacheFile.path;
        changed = true;
        continue;
      }
      try {
        final bytes = await rs.getCoverBytes(song.path!);
        await cacheFile.writeAsBytes(bytes);
        song.coverUrl = cacheFile.path;
        changed = true;
      } catch (_) {
        // 单个提取失败不影响其他
      }
    }
    if (changed) notifyListeners();
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
        } else if (event is RemoteCommand) {
          _handleRemoteCommand(event);
        }
      });
      if (rs.rustAvailable) {
        await rs.initRingbuf();
        // 应用已保存的 DSP 设置到全局管线
        await _applyDsp();
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
    _updateLockScreenMetadata();
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
      await _updateLockScreenMetadata();
      startPlayback();
    }
  }

  /// 启动 Rust 后台解码线程，直接推 ringbuf
  Future<void> _playPcm(Song song) async {
    if (song.path != null && rs.rustAvailable) {
      debugPrint('[Playback] start Rust decoder for ${song.title}');
      await rs.stopDecoder();
      await rs.startDecoder(song.path!, seekSecs: null);
      await _waitFirstFrame();
      await _bufferRingbuf();
    } else {
      debugPrint('[Playback] no path or rust, skipping play');
    }
    // 解码器重置完成后，钩子可触发后续（测试用它注入延迟/记录）
    await startDecoderHook(song);
  }

  /// 等待解码器首帧就绪（首帧到后 ringbuf 开始填充）
  Future<void> _waitFirstFrame() async {
    try {
      await audio_out.waitForReady(timeoutMs: BigInt.from(3000));
    } catch (_) {}
  }

  /// 等待 ringbuf 缓冲足够数据
  Future<void> _bufferRingbuf() async {
    const targetSamples = 16384;
    for (var i = 0; i < 100; i++) {
      try {
        final occ = await audio_out.debugOccupied();
        if (occ >= BigInt.from(targetSamples)) return;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  /// 从 seek 位置重启 Rust 解码器
  Future<void> _restartStreamFrom(double posMs, String path, [int? token]) async {
    if (!_nativeReady || !rs.rustAvailable) return;
    final seekSecs = (posMs / 1000.0).clamp(0.0, double.infinity);
    debugPrint('[Seek] restart decoder at ${seekSecs}s');

    // seek 期间暂停 native 输出，避免 ringbuf 清空/重建时回调拉空产生杂音
    await _nativeAudio.pause();
    if (token != null && token != _seekToken) return;
    await rs.stopDecoder();
    if (token != null && token != _seekToken) return;
    await rs.startDecoder(path, seekSecs: seekSecs);
    if (token != null && token != _seekToken) return;
    await _waitFirstFrame();
    if (token != null && token != _seekToken) return;
    await _bufferRingbuf();
    if (token != null && token != _seekToken) return;
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
      // 更新锁屏进度
      _nativeAudio.updatePosition(_position);
      if (_position >= song.duration.inMilliseconds) {
        _position = song.duration.inMilliseconds.toDouble();
        _progressTimer?.cancel();
        _nativeAudio.stop();
        next();
      }
      notifyListeners();
    });
  }

  //── seek ──

  /// 拖动进度条：拖动中只更新 UI，不 seek。抬手时（immediate=true）才跳转
  void seek(double value, {bool immediate = false}) {
    final song = currentSong;
    if (song == null) return;
    final posMs = value * song.duration.inMilliseconds;
    _position = posMs.clamp(0, song.duration.inMilliseconds.toDouble());
    notifyListeners();

    if (immediate) {
      _seekToPosition(_position);
    }
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
  bool get dspAvailable => true;

  /// 当前频谱（16 频段，0~1）。由 Rust 解码线程实时计算，UI 轮询。
  Future<List<double>> getSpectrum() async {
    if (!rs.rustAvailable) return List.filled(16, 0.0);
    try {
      final raw = await audio_out.getSpectrum();
      return raw.map((e) => e.toDouble()).toList();
    } catch (_) {
      return List.filled(16, 0.0);
    }
  }

  /// underrun 计数（缓冲区抽干次数）
  Future<int> getUnderrunCount() async {
    if (!rs.rustAvailable) return 0;
    try {
      return (await audio_out.getUnderrunCount()).toInt();
    } catch (_) {
      return 0;
    }
  }

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
    // limiter 在 DspPipeline 中随 process 常驻（0dB 砖墙），此处仅持久化开关状态
    notifyListeners();
  }

  void toggleDither() {
    _dspSettings = _dspSettings.copyWith(dither: !_dspSettings.dither);
    PreferencesService.instance.setDspDither(_dspSettings.dither);
    // dither 在 DspPipeline 中随 process 常驻，此处仅持久化开关状态
    notifyListeners();
  }

  /// 应用 EQ 预设（10 段）
  void applyEqPreset(EqPresetKind kind) {
    _dspSettings = _dspSettings.copyWith(preset: kind);
    _applyDsp();
    notifyListeners();
  }

  Future<void> _applyDsp() async {
    if (!rs.rustAvailable) return;
    try {
      await dsp.dspGlobalSetEnabled(enabled: _dspSettings.enabled);
      await dsp.dspGlobalSetCrossfeed(enabled: _dspSettings.crossfeed);
      await dsp.dspGlobalSetStereoWidener(
        enabled: _dspSettings.widener,
        width: 0.5,
      );
      // 预设：Flat 以外应用对应 PEQ 预设
      final preset = _eqPresetFromKind(_dspSettings.preset);
      await dsp.dspGlobalApplyPreset(preset: preset);
    } catch (_) {}
  }

  EqPreset _eqPresetFromKind(EqPresetKind kind) {
    switch (kind) {
      case EqPresetKind.flat:
        return EqPreset.flat;
      case EqPresetKind.rock:
        return EqPreset.rock;
      case EqPresetKind.pop:
        return EqPreset.pop;
      case EqPresetKind.dance:
        return EqPreset.dance;
      case EqPresetKind.classical:
        return EqPreset.classical;
      case EqPresetKind.soft:
        return EqPreset.soft;
      case EqPresetKind.fullBass:
        return EqPreset.fullBass;
      case EqPresetKind.fullTreble:
        return EqPreset.fullTreble;
      case EqPresetKind.techno:
        return EqPreset.techno;
      case EqPresetKind.vocals:
        return EqPreset.vocals;
    }
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

  // ── 锁屏控制 ──

  /// 处理锁屏/控制中心远程命令
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

  /// 更新锁屏显示信息
  Future<void> _updateLockScreenMetadata() async {
    if (!_nativeReady) return;
    final song = currentSong;
    if (song == null) return;
    // 惰性提取封面缓存
    await _ensureCoverCached(song);
    await _nativeAudio.updateMetadata(
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration.inMilliseconds / 1000.0,
      filePath: song.path,
    );
  }

  /// 确保封面已缓存（已有缓存或没封面则跳过）
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
    } catch (_) {}
  }
}

enum LoopMode { list, single, shuffle }

enum EqPresetKind {
  flat,
  rock,
  pop,
  dance,
  classical,
  soft,
  fullBass,
  fullTreble,
  techno,
  vocals,
}

class DspSettings {
  final bool enabled;
  final bool crossfeed;
  final bool widener;
  final bool limiter;
  final bool dither;
  final EqPresetKind preset;

  const DspSettings({
    this.enabled = false,
    this.crossfeed = false,
    this.widener = false,
    this.limiter = false,
    this.dither = false,
    this.preset = EqPresetKind.flat,
  });

  DspSettings copyWith({
    bool? enabled,
    bool? crossfeed,
    bool? widener,
    bool? limiter,
    bool? dither,
    EqPresetKind? preset,
  }) =>
      DspSettings(
        enabled: enabled ?? this.enabled,
        crossfeed: crossfeed ?? this.crossfeed,
        widener: widener ?? this.widener,
        limiter: limiter ?? this.limiter,
        dither: dither ?? this.dither,
        preset: preset ?? this.preset,
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
