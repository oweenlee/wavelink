import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../domain/models/song.dart';
import '../../../../data/repositories/song_repository.dart';
import '../../../../data/repositories/audio_engine_repository.dart';
import '../../../../data/repositories/preferences_repository.dart';

class LibraryProvider extends ChangeNotifier {
  LibraryProvider({
    required SongRepository songRepo,
    required AudioEngineRepository engineRepo,
    required PreferencesRepository prefsRepo,
  })  : _songRepo = songRepo,
        _engineRepo = engineRepo,
        _prefsRepo = prefsRepo;

  final SongRepository _songRepo;
  final AudioEngineRepository _engineRepo;
  final PreferencesRepository _prefsRepo;
  final Set<String> _favoriteIds = {};
  List<Song> _importedSongs = [];
  bool _scanDone = false;

  List<Song> Function() queueSupplier = () => [];
  Song? Function() currentSongSupplier = () => null;

  List<Song> get importedSongs => _importedSongs;
  List<Song> get allSongs => _importedSongs;
  bool get scanDone => _scanDone;

  List<Song> get favoriteSongs =>
      allKnownSongs.where((s) => _favoriteIds.contains(s.id)).toList();

  bool get isFavorite {
    final song = currentSongSupplier();
    return song != null && _favoriteIds.contains(song.id);
  }

  bool isSongFavorite(String songId) => _favoriteIds.contains(songId);

  List<Song> get allKnownSongs {
    final ids = <String>{};
    final out = <Song>[];
    for (final s in [..._importedSongs, ...queueSupplier()]) {
      if (ids.add(s.id)) out.add(s);
    }
    return out;
  }

  VoidCallback? onSongsLoaded;
  VoidCallback? onSongsAdded;
  VoidCallback? onSongsRescanned;

  // ── 收藏 ──

  void toggleFavorite() {
    final song = currentSongSupplier();
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
    _prefsRepo.setFavorites(_favoriteIds);
  }

  void loadFavoritesPrefs() {
    _favoriteIds.addAll(_prefsRepo.favorites);
  }

  // ── 导入与扫描 ──

  Future<bool> scanMediaStore() async {
    final songs = await _songRepo.scanMediaStore();
    if (songs.isEmpty) return false;
    final newPaths =
        songs.where((s) => s.path != null).map((s) => s.path!).toSet();
    _importedSongs = [
      ...songs,
      ..._importedSongs
          .where((s) => s.path == null || !newPaths.contains(s.path)),
    ];
    _songRepo.setCachedSongs(_importedSongs);
    onImportedSongsLoaded(_importedSongs);
    notifyListeners();
    return true;
  }

  Future<void> scanImported() async {
    final songs = await _songRepo.scanDocuments();
    if (songs.isNotEmpty) {
      _importedSongs = songs;
      _songRepo.setCachedSongs(songs);
      onImportedSongsLoaded(songs);
    }
    _scanDone = true;
    notifyListeners();
  }

  Future<void> scanAllSources() async {
    final songs = await _songRepo.scanAll();
    if (songs.isNotEmpty) {
      _importedSongs = songs;
      _songRepo.setCachedSongs(songs);
      onImportedSongsLoaded(songs);
    }
    _scanDone = true;
    notifyListeners();
  }

  void onImportedSongsLoaded(List<Song> songs) {
    onSongsLoaded?.call();
  }

  Future<void> batchExtractCovers(List<Song> songs) async {
    if (!_engineRepo.rustAvailable) return;
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
        final bytes = await _engineRepo.getCoverBytes(song.path!);
        await cacheFile.writeAsBytes(bytes);
        song.coverUrl = cacheFile.path;
        changed = true;
      } catch (e) {
        debugPrint('[Library] 提取封面失败: $e');
      }
    }
    if (changed) notifyListeners();
  }

  Future<int> importFromPicker() async {
    final songs = await _songRepo.pickAndImport();
    if (songs.isEmpty) return 0;
    final existingPaths =
        _importedSongs.where((s) => s.path != null).map((s) => s.path!).toSet();
    final newSongs = songs
        .where((s) => s.path == null || !existingPaths.contains(s.path))
        .toList();
    if (newSongs.isEmpty) return 0;
    _importedSongs = [..._importedSongs, ...newSongs];
    _songRepo.addSongs(newSongs);
    onImportAdded(newSongs);
    notifyListeners();
    return newSongs.length;
  }

  void onImportAdded(List<Song> songs) {
    onSongsAdded?.call();
  }

  Future<void> rescanImported() async {
    final songs = await _songRepo.scanDocuments();
    _importedSongs = songs;
    _songRepo.setCachedSongs(songs);
    onRescan(songs);
    notifyListeners();
  }

  void onRescan(List<Song> songs) {
    onSongsRescanned?.call();
  }

  // ── 播放列表 ──

  Map<String, List<String>> get playlists => _prefsRepo.playlists;

  Future<void> saveCurrentQueueAsPlaylist(String name) async {
    final ids = queueSupplier().map((s) => s.id).toList();
    await _prefsRepo.savePlaylist(name, ids);
    notifyListeners();
  }

  Future<void> savePlaylist(String name, List<String> songIds) async {
    await _prefsRepo.savePlaylist(name, songIds);
    notifyListeners();
  }

  List<Song> playlistSongs(String name) {
    final ids = playlists[name] ?? [];
    final byId = {for (final s in allKnownSongs) s.id: s};
    return ids.where((id) => byId.containsKey(id)).map((id) => byId[id]!).toList();
  }
}
