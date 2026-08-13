export '../../../../domain/models/playback_types.dart';

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../domain/models/song.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../../data/repositories/preferences_repository.dart';
import '../../../../data/services/rust_service.dart' show AnalyzeResult;
import '../../../core/providers/repositories.dart';
import 'audio_player_provider.dart';
import 'queue_provider.dart';
import '../../library/view_models/library_provider.dart';
import '../../settings/view_models/dsp_provider.dart';

/// 播放编排门面：跨 Notifier 协作（曲终切歌、库加载同步队列、偏好加载）。
/// 自身不持有状态，状态全部位于 player/queue/library/dsp 各 Notifier。
class PlaybackController {
  PlaybackController(this._ref) {
    // 接线为纯回调赋值，构造期同步执行安全
    _wire();
  }

  /// 启动副作用：偏好加载、引擎初始化、曲库恢复（仅缓存，不自动扫描）。
  /// 必须在 playbackControllerProvider 构建完成后由调用方显式触发
  /// （Riverpod 禁止在 provider 初始化期间修改其它 provider）。
  void bootstrap() {
    _loadPreferences();
    unawaited(_initEngine());
    unawaited(_bootstrapLibrary());
  }

  /// 引擎初始化完成后再下发已持久化的 DSP/EQ 状态。
  /// 顺序不能换：init 前引擎不存在，applyDsp 是空操作，重启后设置全丢。
  Future<void> _initEngine() async {
    await _player.init();
    await _dsp.applyDsp();
    await _dsp.applyEqToEngine();
  }

  /// 曲库就绪编排：以缓存曲库初始化队列并尝试恢复断点。
  /// 不做系统媒体库扫描（discoverSongs）——Apple Music/媒体库权限弹窗
  /// 只在用户主动 Discover 时触发，避免首次启动即弹窗。
  /// 已配置的 NAS 仍自动重连增量导入（重连不申请权限；
  /// 局域网权限弹窗只出现在用户首次主动添加 NAS 时）。
  /// 注意：discoverSongs 成功时其内部回调已触发过 [_onLibrarySongsLoaded]，
  /// 这里用 [_resumeRestored] 守卫兜底，避免二次整体替换覆盖已恢复的队列。
  Future<void> _bootstrapLibrary() async {
    if (!_resumeRestored) {
      _onLibrarySongsLoaded();
    }
    final prefs = _prefsRepo;
    final host = prefs.nasHost;
    final share = prefs.nasShare;
    // NAS 无「启用」开关：配置了 host/share 即视为启用，启动自动导入
    if (host != null && host.isNotEmpty && share != null && share.isNotEmpty) {
      _library.startNasImport(share);
    }
  }

  final Ref _ref;

  PlayerNotifier get _player => _ref.read(playerProvider.notifier);
  QueueNotifier get _queue => _ref.read(queueProvider.notifier);
  LibraryNotifier get _library => _ref.read(libraryProvider.notifier);
  DspNotifier get _dsp => _ref.read(dspProvider.notifier);
  PreferencesRepository get _prefsRepo =>
      _ref.read(preferencesRepositoryProvider);

  void _wire() {
    _library.onSongsLoaded = _onLibrarySongsLoaded;
    _library.onSongsAdded = _onLibrarySongsAdded;

    _player.onTrackEnd = () {
      next();
    };
    // 锁屏/控制中心 next/previous 命令 → 复用播放器切歌逻辑
    _player.onNext = () {
      next();
    };
    _player.onPrevious = () {
      previous();
    };
  }

  /// 是否已尝试恢复断点（幂等守卫，避免 NAS 导入等多次 onSongsLoaded 重复恢复）
  bool _resumeRestored = false;

  void _onLibrarySongsLoaded() {
    final songs = _ref.read(libraryProvider).importedSongs;
    // 仅首次以曲库初始化队列并尝试恢复断点；之后的 onSongsLoaded 回调
    // （NAS 导入、Discover/Subsonic 扫描等）不再整体替换队列，否则会把
    // 已恢复的断点队列冲成全库顺序（onImportedSongsLoaded 置 currentIndex=0）。
    // 语义：队列 = 用户会话上下文，扫描新增歌不自动入队；用户点播时经
    // playSongById 兜底追加到队尾（可播性不丢）。
    if (!_resumeRestored) {
      _resumeRestored = true;
      _queue.onImportedSongsLoaded(songs);
      _restoreResume();
    }
    _player.setCurrentSong(_ref.read(queueProvider).currentSong);
    _library.batchExtractCovers(songs);
  }

  /// 断点续播：恢复上次会话的队列 + 当前索引 + 播放位置（不自动播放）。
  /// 歌曲按 id 匹配当前曲库，失效的 id 静默丢弃。
  void _restoreResume() {
    final prefs = _prefsRepo;
    final ids = prefs.resumeQueue;
    if (ids.isEmpty) return;
    final byId = {
      for (final s in _ref.read(libraryProvider).importedSongs) s.id: s,
    };
    final restored = <Song>[];
    for (final id in ids) {
      final s = byId[id];
      if (s != null) restored.add(s);
    }
    if (restored.isEmpty) return;
    final idx = prefs.resumeIndex < restored.length ? prefs.resumeIndex : 0;
    _queue.setQueue(restored, startIndex: idx);
    _player.setCurrentSong(restored[idx]);
    _player.setPosition(prefs.resumePositionMs);
  }

  void _onLibrarySongsAdded() {
    _queue.onImportAdded(_ref.read(libraryProvider).importedSongs);
  }

  void _loadPreferences() {
    _player.setVolume(_prefsRepo.volume);
    _player.setBitPerfect(_prefsRepo.bitPerfect);
    // 设置页响应式字段同样从偏好同步（重启后显示与偏好一致）
    _player.setReplayGain(_prefsRepo.replayGain);
    _player.setDynamicColor(_prefsRepo.dynamicColor);
    _player.setCoverBlur(_prefsRepo.coverBlur);
    if (_prefsRepo.shuffle) _queue.toggleShuffle();
    _queue.setLoopMode(
      LoopMode.values.firstWhere(
        (m) => m.name == _prefsRepo.loopMode,
        orElse: () => LoopMode.list,
      ),
    );
    _dsp.loadDspPrefs();
    // 注：持久化 DSP/EQ 状态的下发在 _initEngine（引擎就绪后）执行
    _library.loadFavoritesPrefs();
  }

  // ── 门面 getter ──

  List<Song> get queue => _ref.read(queueProvider).queue;
  int get currentIndex => _ref.read(queueProvider).currentIndex;
  Song? get currentSong => _ref.read(queueProvider).currentSong;
  bool get hasSong => _ref.read(queueProvider).hasSong;
  bool get isPlaying => _ref.read(playerProvider).isPlaying;
  double get position => _ref.read(playerProvider).position;
  double get volume => _ref.read(playerProvider).volume;
  LoopMode get loopMode => _ref.read(queueProvider).loopMode;
  bool get shuffle => _ref.read(queueProvider).shuffle;

  double get progress => _ref.read(playerProvider).progress;
  List<LyricLine>? get currentLyrics => _ref.read(playerProvider).lyrics;
  int get currentLyricLine => _ref.read(playerProvider).currentLyricLine;

  List<Song> get allSongs => _ref.read(libraryProvider).allSongs;
  List<Song> get importedSongs => _ref.read(libraryProvider).importedSongs;
  bool get scanDone => _ref.read(libraryProvider).scanDone;
  List<Song> get favoriteSongs => _library.favoriteSongs();
  bool get isFavorite => _library.isFavorite(currentSong);
  bool isSongFavorite(String songId) =>
      _ref.read(libraryProvider).isSongFavorite(songId);
  Map<String, List<String>> get playlists => _library.playlists;
  List<Song> get allKnownSongs => _library.allKnownSongs();

  DspSettings get dspSettings => _ref.read(dspProvider).dspSettings;
  bool get dspAvailable => _dsp.dspAvailable;

  /// 引擎实时遥测（乐器面板）
  EngineTelemetry get telemetry => _ref.read(playerProvider).telemetry;

  /// 有效 bit-perfect（请求偏好 && 实际链路 && 无 DSP，见 PlayerNotifier）
  bool get effectiveBitPerfect => _player.effectiveBitPerfect;

  /// DSP 是否在动信号（指示器"被旁路/生效中"说明用）
  bool get dspAffectingSignal => _player.dspAffectingSignal;

  AnalyzeResult? getAnalysis(String songId) => _player.getAnalysis(songId);

  // ── 外观偏好 ──

  bool get replayGain => _prefsRepo.replayGain;
  bool get dynamicColor => _prefsRepo.dynamicColor;
  double get coverBlur => _prefsRepo.coverBlur;
  bool get bitPerfect => _prefsRepo.bitPerfect;

  void setReplayGain(bool v) {
    _prefsRepo.setReplayGain(v);
    // 同步到播放器状态供设置页响应式刷新（偏好为唯一事实源）
    _player.setReplayGain(v);
    // 对当前曲目立即生效（切歌时也会按偏好逐首应用）
    _player.applyReplayGainNow();
  }

  void setDynamicColor(bool v) {
    _prefsRepo.setDynamicColor(v);
    _player.setDynamicColor(v);
  }

  void setCoverBlur(double v) {
    _prefsRepo.setCoverBlur(v);
    _player.setCoverBlur(v);
  }

  void setBitPerfect(bool v) {
    _prefsRepo.setBitPerfect(v);
    _player.setBitPerfect(v);
  }

  // ── 门面方法 ──

  bool autoPlayOnQueueSet = true;

  Future<void> Function(Song) get startDecoderHook => _player.startDecoderHook;
  set startDecoderHook(Future<void> Function(Song) hook) {
    _player.startDecoderHook = hook;
  }

  void play() => _player.play();
  void pause() => _player.pause();
  void togglePlay() => _player.togglePlay();
  void startPlayback() => _player.startPlayback();
  void seek(double value, {bool immediate = false}) =>
      _player.seek(value, immediate: immediate);
  void setDragging(bool dragging) => _player.setDragging(dragging);
  void skipForward() => _player.skipForward();
  void skipBackward() => _player.skipBackward();
  set volume(double v) => _player.setVolume(v);

  void next() {
    if (!hasSong) return;
    final q = _ref.read(queueProvider);
    if (q.loopMode == LoopMode.single) {
      _player.playSong(q.currentSong!);
      return;
    }
    final nextIdx = _queue.findNextIndex();
    _queue.advanceTo(nextIdx);
    _player.playSong(_ref.read(queueProvider).currentSong!);
  }

  void previous() {
    if (!hasSong) return;
    if (_ref.read(playerProvider).position > 3000) {
      _player.seekToStart();
    } else {
      final q = _ref.read(queueProvider);
      final prevIdx = (q.currentIndex - 1 + q.queue.length) % q.queue.length;
      _queue.advanceTo(prevIdx);
      _player.playSong(_ref.read(queueProvider).currentSong!);
    }
  }

  void toggleLoopMode() => _queue.toggleLoopMode();
  void setLoopMode(LoopMode mode) => _queue.setLoopMode(mode);

  void setVolume(double v) {
    _player.setVolume(v);
    // 持久化夹紧后的音量（之前只设内存值，重启后丢失；其它设置均有持久化）
    _prefsRepo.setVolume(_ref.read(playerProvider).volume);
  }

  void playSong(Song song) {
    _queue.playSongById(song);
    _player.playSong(song);
  }

  /// 播放队列指定位置的曲目（队列面板点击行）
  void playFromQueue(int index) {
    final q = _ref.read(queueProvider);
    if (index < 0 || index >= q.queue.length) return;
    _queue.advanceTo(index);
    _player.playSong(_ref.read(queueProvider).currentSong!);
  }

  void playAlbum(List<Song> songs, {int startIndex = 0}) {
    _queue.setQueue(songs, startIndex: startIndex);
    _player.playSong(_ref.read(queueProvider).currentSong!);
  }

  void addToQueue(Song song) => _queue.addToQueue(song);
  void playNext(Song song) => _queue.playNext(song);
  void removeFromQueue(int index) {
    final wasCurrent = index == _ref.read(queueProvider).currentIndex;
    _queue.removeFromQueue(index);
    if (wasCurrent) {
      final q = _ref.read(queueProvider);
      if (q.hasSong) {
        _player.playSong(q.currentSong!);
      } else {
        _player.pause();
        _player.setCurrentSong(null);
      }
    }
  }

  void reorderQueue(int oldIndex, int newIndex) =>
      _queue.reorderQueue(oldIndex, newIndex);
  void setQueue(List<Song> songs) {
    _queue.setQueue(songs);
    _player.setCurrentSong(_ref.read(queueProvider).currentSong);
    if (songs.isNotEmpty && autoPlayOnQueueSet) {
      _player.playSong(_ref.read(queueProvider).currentSong!);
    }
  }

  int findNextIndex() => _queue.findNextIndex();

  // ── 频谱 ──
  Future<List<double>> getSpectrum() => _dsp.getSpectrum();

  // ── DSP ──
  void toggleDspEnabled() => _dsp.toggleDspEnabled();
  void toggleCrossfeed() => _dsp.toggleCrossfeed();
  void toggleWidener() => _dsp.toggleWidener();
  void toggleLimiter() => _dsp.toggleLimiter();
  void toggleDither() => _dsp.toggleDither();
  void toggleNoiseShaping() => _dsp.toggleNoiseShaping();

  // ── AutoEQ ──
  String? get autoEqModel => _ref.read(dspProvider).autoEqModel;
  void setAutoEq(String? model) => _dsp.setAutoEq(model);
  Future<List<String>> getAutoEqCatalog() => _dsp.getAutoEqCatalog();

  // ── EQ ──
  List<double> get eqValues => _ref.read(dspProvider).eqValues;
  String get eqPreset => _ref.read(dspProvider).eqPreset;
  Future<void> applyEqPreset(String name) => _dsp.applyEqPreset(name);
  Future<void> setEqBand(int index, double gainDb) =>
      _dsp.setEqBand(index, gainDb);

  // ── 库操作 ──
  Future<bool> discoverSongs() => _library.discoverSongs();
  Future<int> importFromPicker() => _library.importFromPicker();
  Future<bool> scanSubsonic() => _library.scanSubsonic();
  Future<bool> scanSmb(String sharePath) => _library.scanSmb(sharePath);

  /// 从曲库删除歌曲：曲库条目/收藏/沙盒内物理文件清理 +
  /// 播放队列同步移除。
  Future<void> removeSong(Song song) async {
    await _library.removeSong(song);
    _queue.removeSongById(song.id);
  }

  void toggleFavorite() => _library.toggleFavoriteFor(currentSong);
  void setFavorite(String songId, bool favorite) =>
      _library.setFavorite(songId, favorite);
  Future<void> saveCurrentQueueAsPlaylist(String name) =>
      _library.saveCurrentQueueAsPlaylist(name);
  Future<void> savePlaylist(String name, List<String> songIds) =>
      _library.savePlaylist(name, songIds);
  List<Song> playlistSongs(String name) => _library.playlistSongs(name);
}

final playbackControllerProvider = Provider<PlaybackController>((ref) {
  return PlaybackController(ref);
});
