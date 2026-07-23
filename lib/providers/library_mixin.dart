import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../services/import_service.dart';
import '../services/preferences_service.dart';
import '../services/rust_service.dart' as rs;

mixin LibraryMixin on ChangeNotifier {
  final Set<String> _favoriteIds = {};
  List<Song> _importedSongs = [];
  bool _scanDone = false;

  List<Song> get importedSongs => _importedSongs;
  List<Song> get allSongs => _importedSongs;
  bool get scanDone => _scanDone;

  List<Song> get favoriteSongs =>
      allKnownSongs.where((s) => _favoriteIds.contains(s.id)).toList();

  bool get isFavorite {
    final song = currentSongForFav();
    return song != null && _favoriteIds.contains(song.id);
  }

  bool isSongFavorite(String songId) => _favoriteIds.contains(songId);

  List<Song> get allKnownSongs {
    final ids = <String>{};
    final out = <Song>[];
    for (final s in [..._importedSongs, ...queueSongsForLib()]) {
      if (ids.add(s.id)) out.add(s);
    }
    return out;
  }

  // ── 由 PlaybackProvider 实现的抽象 ──

  Song? currentSongForFav();
  List<Song> queueSongsForLib();

  // ── 收藏 ──

  void toggleFavorite() {
    final song = currentSongForFav();
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
    PreferencesService.instance.setFavorites(_favoriteIds);
  }

  void loadFavoritesPrefs() {
    _favoriteIds.addAll(PreferencesService.instance.favorites);
  }

  // ── 导入与扫描 ──

  Future<void> scanImported() async {
    final songs = await ImportService.scanDocuments();
    if (songs.isNotEmpty) {
      _importedSongs = songs;
      onImportedSongsLoaded(songs);
    }
    _scanDone = true;
    notifyListeners();
  }

  void onImportedSongsLoaded(List<Song> songs) {
    // 子类覆盖：设置队列
  }

  Future<void> batchExtractCovers(List<Song> songs) async {
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
      } catch (e) {
        debugPrint('[Library] 提取封面失败: $e');
      }
    }
    if (changed) notifyListeners();
  }

  Future<int> importFromPicker() async {
    final songs = await ImportService.pickAndImport();
    if (songs.isEmpty) return 0;
    _importedSongs = [..._importedSongs, ...songs];
    onImportAdded(songs);
    notifyListeners();
    return songs.length;
  }

  void onImportAdded(List<Song> songs) {
    // 子类覆盖：追加到队列
  }

  Future<void> rescanImported() async {
    final songs = await ImportService.scanDocuments();
    _importedSongs = songs;
    onRescan(songs);
    notifyListeners();
  }

  void onRescan(List<Song> songs) {
    // 子类覆盖：更新队列中已有歌曲的元数据
  }

  // ── 播放列表 ──

  Map<String, List<String>> get playlists => PreferencesService.instance.playlists;

  Future<void> saveCurrentQueueAsPlaylist(String name) async {
    final ids = queueSongsForLib().map((s) => s.id).toList();
    await PreferencesService.instance.savePlaylist(name, ids);
    notifyListeners();
  }

  Future<void> savePlaylist(String name, List<String> songIds) async {
    await PreferencesService.instance.savePlaylist(name, songIds);
    notifyListeners();
  }

  List<Song> playlistSongs(String name) {
    final ids = playlists[name] ?? [];
    final byId = {for (final s in allKnownSongs) s.id: s};
    return ids.where((id) => byId.containsKey(id)).map((id) => byId[id]!).toList();
  }
}
