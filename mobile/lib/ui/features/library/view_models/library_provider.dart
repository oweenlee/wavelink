import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../domain/models/song.dart';
import '../../../core/providers/repositories.dart';
import '../../playback/view_models/queue_provider.dart';

class LibraryState {
  final List<Song> importedSongs;
  final bool scanDone;
  final Set<String> favoriteIds;

  const LibraryState({
    this.importedSongs = const [],
    this.scanDone = false,
    this.favoriteIds = const {},
  });

  List<Song> get allSongs => importedSongs;

  bool isSongFavorite(String songId) => favoriteIds.contains(songId);

  LibraryState copyWith({
    List<Song>? importedSongs,
    bool? scanDone,
    Set<String>? favoriteIds,
  }) {
    return LibraryState(
      importedSongs: importedSongs ?? this.importedSongs,
      scanDone: scanDone ?? this.scanDone,
      favoriteIds: favoriteIds ?? this.favoriteIds,
    );
  }
}

class LibraryNotifier extends Notifier<LibraryState> {
  bool _isScanning = false;

  /// 曲目加载/新增后的编排回调（由 PlaybackController 接线）。
  VoidCallback? onSongsLoaded;
  VoidCallback? onSongsAdded;

  @override
  LibraryState build() => const LibraryState();

  /// 导入歌曲 + 播放队列合并去重后的全集（收藏/播放列表查找用）。
  List<Song> allKnownSongs() {
    final ids = <String>{};
    final out = <Song>[];
    final queue = ref.read(queueProvider).queue;
    for (final s in [...state.importedSongs, ...queue]) {
      if (ids.add(s.id)) out.add(s);
    }
    return out;
  }

  List<Song> favoriteSongs() =>
      allKnownSongs().where((s) => state.favoriteIds.contains(s.id)).toList();

  bool isFavorite(Song? song) =>
      song != null && state.favoriteIds.contains(song.id);

  // ── 收藏 ──

  void toggleFavoriteFor(Song? song) {
    if (song == null) return;
    final id = song.id;
    final ids = Set<String>.from(state.favoriteIds);
    if (ids.contains(id)) {
      ids.remove(id);
    } else {
      ids.add(id);
    }
    state = state.copyWith(favoriteIds: ids);
    _persistFavorites();
  }

  void setFavorite(String songId, bool favorite) {
    final ids = Set<String>.from(state.favoriteIds);
    if (favorite) {
      ids.add(songId);
    } else {
      ids.remove(songId);
    }
    state = state.copyWith(favoriteIds: ids);
    _persistFavorites();
  }

  void _persistFavorites() {
    ref.read(preferencesRepositoryProvider).setFavorites(state.favoriteIds);
  }

  void loadFavoritesPrefs() {
    final favorites = ref.read(preferencesRepositoryProvider).favorites;
    state = state.copyWith(favoriteIds: {...state.favoriteIds, ...favorites});
  }

  // ── 导入与扫描 ──

  Future<bool> discoverSongs() async {
    if (_isScanning) return false;
    _isScanning = true;
    try {
      final songRepo = ref.read(songRepositoryProvider);
      final mediaSongs = await songRepo.scanMediaStore();
      final docSongs = await songRepo.scanDocuments();
      final scannedSongs = [...mediaSongs, ...docSongs];

      // 按 path 去重（扫描结果内部）
      final seen = <String>{};
      scannedSongs.retainWhere((s) {
        if (s.path == null) return true;
        return seen.add(s.path!);
      });

      if (scannedSongs.isEmpty) return false;

      // 合并到已有列表：扫描到的新 path 替换已有，保留已有的其他歌曲
      final scannedPaths = scannedSongs
          .where((s) => s.path != null)
          .map((s) => s.path!)
          .toSet();
      final merged = [
        ...scannedSongs,
        ...state.importedSongs.where(
          (s) => s.path == null || !scannedPaths.contains(s.path),
        ),
      ];

      state = state.copyWith(importedSongs: merged, scanDone: true);
      songRepo.setCachedSongs(merged);
      onSongsLoaded?.call();
      return true;
    } finally {
      _isScanning = false;
    }
  }

  Future<bool> scanSubsonic() async {
    if (_isScanning) return false;
    _isScanning = true;
    try {
      final songRepo = ref.read(songRepositoryProvider);
      final songs = await songRepo.scanSubsonic();
      if (songs.isEmpty) return false;
      final newPaths = songs
          .where((s) => s.path != null)
          .map((s) => s.path!)
          .toSet();
      final merged = [
        ...songs,
        ...state.importedSongs.where(
          (s) => s.path == null || !newPaths.contains(s.path),
        ),
      ];
      state = state.copyWith(importedSongs: merged);
      songRepo.setCachedSongs(merged);
      onSongsLoaded?.call();
      return true;
    } finally {
      _isScanning = false;
    }
  }

  Future<bool> scanSmb(String sharePath) async {
    if (_isScanning) return false;
    _isScanning = true;
    try {
      final songRepo = ref.read(songRepositoryProvider);
      // 增量合并：每批下载完立即入库+持久化，
      // UI 实时可见、中途退出也保留已扫部分
      final songs = await songRepo.scanSmb(sharePath, onBatch: (batch) {
        final batchPaths = batch
            .where((s) => s.path != null)
            .map((s) => s.path!)
            .toSet();
        final merged = [
          ...batch,
          ...state.importedSongs.where(
            (s) => s.path == null || !batchPaths.contains(s.path),
          ),
        ];
        state = state.copyWith(importedSongs: merged);
        songRepo.setCachedSongs(merged);
        onSongsLoaded?.call();
      });
      if (songs.isEmpty) return false;
      // 最终一致性合并（与增量幂等），保证返回值统计准确
      final newPaths = songs
          .where((s) => s.path != null)
          .map((s) => s.path!)
          .toSet();
      final merged = [
        ...songs,
        ...state.importedSongs.where(
          (s) => s.path == null || !newPaths.contains(s.path),
        ),
      ];
      state = state.copyWith(importedSongs: merged);
      songRepo.setCachedSongs(merged);
      onSongsLoaded?.call();
      return true;
    } finally {
      _isScanning = false;
    }
  }

  Future<void> batchExtractCovers(List<Song> songs) async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/.covers');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

    // 待处理的歌曲（无封面缓存）。
    // 不依赖 hasCover 标记（_fileToSong 降级导入时未设），
    // 有本地文件路径但无 coverUrl 的就尝试提取——Rust 读不到封面会自然失败。
    final pending = songs
        .where((s) => s.path != null && s.coverUrl == null)
        .toList();
    if (pending.isEmpty) return;

    var changed = false;
    // 限制并发，避免一次性打满 FRB 线程池；每组并行完成后统一刷新
    const batchSize = 4;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(
        i,
        i + batchSize > pending.length ? pending.length : i + batchSize,
      );
      await Future.wait(batch.map((song) async {
        final cacheFile = File('${cacheDir.path}/${song.path!.hashCode}.jpg');
        if (await cacheFile.exists()) {
          song.coverUrl = cacheFile.path;
          changed = true;
          return;
        }
        try {
          final bytes = await engineRepo.getCoverBytes(song.path!);
          await cacheFile.writeAsBytes(bytes);
          song.coverUrl = cacheFile.path;
          changed = true;
        } catch (e) {
          debugPrint('[Library] 提取封面失败: $e');
        }
      }));
    }
    if (changed) {
      // Song.coverUrl 是可变字段，触发一次状态更新以刷新 UI
      state = state.copyWith(importedSongs: List<Song>.from(state.importedSongs));
    }
  }

  Future<int> importFromPicker() async {
    final songRepo = ref.read(songRepositoryProvider);
    final songs = await songRepo.pickAndImport();
    if (songs.isEmpty) return 0;
    final existingPaths = state.importedSongs
        .where((s) => s.path != null)
        .map((s) => s.path!)
        .toSet();
    final newSongs = songs
        .where((s) => s.path == null || !existingPaths.contains(s.path))
        .toList();
    if (newSongs.isEmpty) return 0;
    state = state.copyWith(
      importedSongs: [...state.importedSongs, ...newSongs],
    );
    songRepo.addSongs(newSongs);
    onSongsAdded?.call();
    return newSongs.length;
  }

  // ── 播放列表 ──

  Map<String, List<String>> get playlists =>
      ref.read(preferencesRepositoryProvider).playlists;

  Future<void> saveCurrentQueueAsPlaylist(String name) async {
    final ids = ref.read(queueProvider).queue.map((s) => s.id).toList();
    await ref.read(preferencesRepositoryProvider).savePlaylist(name, ids);
    state = state.copyWith(); // 触发 UI 刷新播放列表区域
  }

  Future<void> savePlaylist(String name, List<String> songIds) async {
    await ref.read(preferencesRepositoryProvider).savePlaylist(name, songIds);
    state = state.copyWith(); // 触发 UI 刷新播放列表区域
  }

  List<Song> playlistSongs(String name) {
    final ids = playlists[name] ?? [];
    final byId = {for (final s in allKnownSongs()) s.id: s};
    return ids
        .where((id) => byId.containsKey(id))
        .map((id) => byId[id]!)
        .toList();
  }
}

final libraryProvider = NotifierProvider<LibraryNotifier, LibraryState>(
  LibraryNotifier.new,
);
