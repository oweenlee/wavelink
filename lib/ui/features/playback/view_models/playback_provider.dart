export '../../../../domain/models/playback_types.dart';

import 'package:flutter/material.dart';
import '../../../../domain/models/song.dart';
import '../../../../domain/models/lyric_line.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../../data/repositories/audio_engine_repository.dart';
import '../../../../data/repositories/song_repository.dart';
import '../../../../data/repositories/preferences_repository.dart';
import '../../../../data/services/rust_service.dart' show AnalyzeResult;
import 'audio_player_provider.dart';
import 'queue_provider.dart';
import '../../library/view_models/library_provider.dart';
import '../../settings/view_models/dsp_provider.dart';

class PlaybackProvider extends ChangeNotifier {
  final AudioPlayerProvider audioPlayer;
  final QueueProvider queueProvider;
  final LibraryProvider library;
  final DspProvider dsp;
  final PreferencesRepository _prefsRepo;

  PlaybackProvider({
    required AudioEngineRepository engineRepo,
    required SongRepository songRepo,
    required PreferencesRepository prefsRepo,
  })  : audioPlayer = AudioPlayerProvider(engineRepo: engineRepo),
        queueProvider = QueueProvider(prefsRepo: prefsRepo),
        library = LibraryProvider(
          songRepo: songRepo,
          engineRepo: engineRepo,
          prefsRepo: prefsRepo,
        ),
        dsp = DspProvider(engineRepo: engineRepo, prefsRepo: prefsRepo),
        _prefsRepo = prefsRepo {
    _wire();
    _loadPreferences();
    audioPlayer.init();
    library.scanImported();
  }

  void _wire() {
    library.queueSupplier = () => queueProvider.queue;
    library.currentSongSupplier = () => queueProvider.currentSong;
    library.onSongsLoaded = () => _onLibrarySongsLoaded();
    library.onSongsAdded = () => _onLibrarySongsAdded();
    library.onSongsRescanned = () => _onLibrarySongsRescanned();

    audioPlayer.onTrackEnd = () {
      next();
    };

    audioPlayer.addListener(_onAudioPlayerChange);
    library.addListener(_onLibraryChange);
  }

  void _onLibrarySongsLoaded() {
    final songs = library.importedSongs;
    queueProvider.onImportedSongsLoaded(songs);
    audioPlayer.setCurrentSong(queueProvider.currentSong);
    library.batchExtractCovers(songs);
  }

  void _onLibrarySongsAdded() {
    queueProvider.onImportAdded(library.importedSongs);
  }

  void _onLibrarySongsRescanned() {
    queueProvider.onRescan(library.importedSongs);
  }

  void _loadPreferences() {
    audioPlayer.setVolume(_prefsRepo.volume);
    if (_prefsRepo.shuffle) queueProvider.toggleShuffle();
    queueProvider.setLoopMode(LoopMode.values.firstWhere(
      (m) => m.name == _prefsRepo.loopMode,
      orElse: () => LoopMode.list,
    ));
    dsp.loadDspPrefs();
    library.loadFavoritesPrefs();
  }

  @override
  void dispose() {
    audioPlayer.removeListener(_onAudioPlayerChange);
    library.removeListener(_onLibraryChange);
    audioPlayer.dispose();
    super.dispose();
  }

  void _onAudioPlayerChange() {
    notifyListeners();
  }

  void _onLibraryChange() {
    notifyListeners();
  }

  // ── 向后兼容 getter ──

  List<Song> get queue => queueProvider.queue;
  int get currentIndex => queueProvider.currentIndex;
  Song? get currentSong => queueProvider.currentSong;
  bool get hasSong => queueProvider.hasSong;
  bool get isPlaying => audioPlayer.isPlaying;
  double get position => audioPlayer.position;
  double get volume => audioPlayer.volume;
  LoopMode get loopMode => queueProvider.loopMode;
  bool get shuffle => queueProvider.shuffle;

  double get progress => audioPlayer.progress;
  List<LyricLine>? get currentLyrics => audioPlayer.currentLyrics;
  int get currentLyricLine => audioPlayer.currentLyricLine;

  List<Song> get allSongs => library.allSongs;
  List<Song> get importedSongs => library.importedSongs;
  bool get scanDone => library.scanDone;
  List<Song> get favoriteSongs => library.favoriteSongs;
  bool get isFavorite => library.isFavorite;
  bool isSongFavorite(String songId) => library.isSongFavorite(songId);
  Map<String, List<String>> get playlists => library.playlists;
  List<Song> get allKnownSongs => library.allKnownSongs;

  DspSettings get dspSettings => dsp.dspSettings;
  bool get dspAvailable => dsp.dspAvailable;

  AnalyzeResult? getAnalysis(String songId) =>
      audioPlayer.getAnalysis(songId);

  // ── 外观偏好 ──

  bool get replayGain => _prefsRepo.replayGain;
  bool get dynamicColor => _prefsRepo.dynamicColor;
  double get coverBlur => _prefsRepo.coverBlur;
  bool get showSpectrum => _prefsRepo.showSpectrum;

  void setReplayGain(bool v) => _prefsRepo.setReplayGain(v);
  void setDynamicColor(bool v) => _prefsRepo.setDynamicColor(v);
  void setCoverBlur(double v) => _prefsRepo.setCoverBlur(v);
  void setShowSpectrum(bool v) => _prefsRepo.setShowSpectrum(v);

  // ── 向后兼容方法 ──

  bool autoPlayOnQueueSet = true;

  Future<void> Function(Song) get startDecoderHook => audioPlayer.startDecoderHook;
  set startDecoderHook(Future<void> Function(Song) hook) {
    audioPlayer.startDecoderHook = hook;
  }

  void play() => audioPlayer.play();
  void pause() => audioPlayer.pause();
  void togglePlay() => audioPlayer.togglePlay();
  void startPlayback() => audioPlayer.startPlayback();
  void seek(double value, {bool immediate = false}) =>
      audioPlayer.seek(value, immediate: immediate);
  void skipForward() => audioPlayer.skipForward();
  void skipBackward() => audioPlayer.skipBackward();
  set volume(double v) => audioPlayer.setVolume(v);

  void next() {
    if (!hasSong) return;
    if (queueProvider.loopMode == LoopMode.single) {
      audioPlayer.playSong(queueProvider.currentSong!);
      return;
    }
    final nextIdx = queueProvider.findNextIndex();
    queueProvider.advanceTo(nextIdx);
    audioPlayer.playSong(queueProvider.currentSong!);
  }

  void previous() {
    if (!hasSong) return;
    if (audioPlayer.position > 3000) {
      audioPlayer.seekToStart();
    } else {
      final prevIdx =
          (queueProvider.currentIndex - 1 + queueProvider.queue.length) %
              queueProvider.queue.length;
      queueProvider.advanceTo(prevIdx);
      audioPlayer.playSong(queueProvider.currentSong!);
    }
  }

  void toggleLoopMode() => queueProvider.toggleLoopMode();
  void toggleShuffle() => queueProvider.toggleShuffle();

  void setVolume(double v) => audioPlayer.setVolume(v);

  void playSong(Song song) {
    queueProvider.playSongById(song);
    audioPlayer.playSong(song);
  }

  void playAlbum(List<Song> songs, {int startIndex = 0}) {
    queueProvider.setQueue(songs, startIndex: startIndex);
    audioPlayer.playSong(queueProvider.currentSong!);
  }

  void addToQueue(Song song) => queueProvider.addToQueue(song);
  void playNext(Song song) => queueProvider.playNext(song);
  void removeFromQueue(int index) {
    final wasCurrent = index == queueProvider.currentIndex;
    queueProvider.removeFromQueue(index);
    if (wasCurrent) {
      if (queueProvider.hasSong) {
        audioPlayer.playSong(queueProvider.currentSong!);
      } else {
        audioPlayer.pause();
        audioPlayer.setCurrentSong(null);
      }
    }
  }
  void reorderQueue(int oldIndex, int newIndex) =>
      queueProvider.reorderQueue(oldIndex, newIndex);
  void setQueue(List<Song> songs) {
    queueProvider.setQueue(songs);
    audioPlayer.setCurrentSong(queueProvider.currentSong);
    if (songs.isNotEmpty && autoPlayOnQueueSet) {
      audioPlayer.playSong(queueProvider.currentSong!);
    }
  }

  int findNextIndex() => queueProvider.findNextIndex();

  // ── 频谱 ──
  Future<List<double>> getSpectrum() => dsp.getSpectrum();

  // ── DSP ──
  void toggleDspEnabled() => dsp.toggleDspEnabled();
  void toggleCrossfeed() => dsp.toggleCrossfeed();
  void toggleWidener() => dsp.toggleWidener();
  void toggleLimiter() => dsp.toggleLimiter();
  void toggleDither() => dsp.toggleDither();
  void applyEqPreset(EqPresetKind kind) => dsp.applyEqPreset(kind);

  // ── 库操作 ──
  Future<bool> scanMediaStore() => library.scanMediaStore();
  Future<void> scanImported() => library.scanImported();
  Future<void> scanAllSources() => library.scanAllSources();
  Future<int> importFromPicker() => library.importFromPicker();
  Future<void> rescanImported() => library.rescanImported();
  void toggleFavorite() => library.toggleFavorite();
  void setFavorite(String songId, bool favorite) =>
      library.setFavorite(songId, favorite);
  Future<void> saveCurrentQueueAsPlaylist(String name) =>
      library.saveCurrentQueueAsPlaylist(name);
  Future<void> savePlaylist(String name, List<String> songIds) =>
      library.savePlaylist(name, songIds);
  List<Song> playlistSongs(String name) => library.playlistSongs(name);
}
