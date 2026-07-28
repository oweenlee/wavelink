export '../models/playback_types.dart';

import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/lyric_line.dart';
import '../models/playback_types.dart';
import '../services/preferences_service.dart';
import '../services/rust_service.dart' as rs;
import 'audio_player_provider.dart';
import 'queue_provider.dart';
import 'library_provider.dart';
import 'dsp_provider.dart';

class PlaybackProvider extends ChangeNotifier {
  final AudioPlayerProvider audioPlayer = AudioPlayerProvider();
  final QueueProvider queueProvider = QueueProvider();
  final LibraryProvider library = LibraryProvider();
  final DspProvider dsp = DspProvider();

  PlaybackProvider() {
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
    final prefs = PreferencesService.instance;
    audioPlayer.setVolume(prefs.volume);
    if (prefs.shuffle) queueProvider.toggleShuffle();
    queueProvider.setLoopMode(LoopMode.values.firstWhere(
      (m) => m.name == prefs.loopMode,
      orElse: () => LoopMode.list,
    ));
    dsp.loadDspPrefs();
    library.loadFavoritesPrefs();
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    super.dispose();
  }

  // ── 向后兼容 getter（委托到子 Provider） ──

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

  rs.AnalyzeResult? getAnalysis(String songId) =>
      audioPlayer.getAnalysis(songId);

  // ── 外观偏好 ──

  bool get replayGain => true;
  bool get dynamicColor => true;
  double get coverBlur => 0.7;
  bool get showSpectrum => true;

  void setReplayGain(bool v) {}
  void setDynamicColor(bool v) {}
  void setCoverBlur(double v) {}
  void setShowSpectrum(bool v) {}

  // ── 向后兼容方法（委托） ──

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
      audioPlayer.seekToStart();
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
          (queueProvider.currentIndex - 1 + queueProvider.queue.length) % queueProvider.queue.length;
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
  void removeFromQueue(int index) => queueProvider.removeFromQueue(index);
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
