import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../domain/models/song.dart';
import '../../../core/providers/repositories.dart';
import '../../playback/view_models/queue_provider.dart';

/// copyWith 哨兵值：区分「未传入」与「显式传 null 清空」
const _unset = Object();

/// 取消 NAS 导入的哨兵异常，由 [_runNasImport] 捕获并静默结束
class NASImportCancelled implements Exception {
  const NASImportCancelled();
}

class LibraryState {
  final List<Song> importedSongs;
  final bool scanDone;
  final Set<String> favoriteIds;

  /// NAS 后台导入是否进行中（曲库顶部展示进度条）
  final bool nasImporting;
  /// NAS 后台导入已入库的首批歌曲数增量
  final int nasImportedCount;
  /// NAS 后台导入失败信息（空表示无错误）
  final String? nasImportError;

  const LibraryState({
    this.importedSongs = const [],
    this.scanDone = false,
    this.favoriteIds = const {},
    this.nasImporting = false,
    this.nasImportedCount = 0,
    this.nasImportError,
  });

  /// 曲库可见歌曲：按来源开关过滤（关闭的来源不在曲库展示）。
  /// 队列/收藏/播放不受影响（各自独立数据源）。
  /// 队列/收藏/播放不受影响（各自独立数据源）。
  List<Song> get allSongs {
    final prefs = PreferencesService.instance;
    return importedSongs
        .where((s) => prefs.showSource(s.source))
        .toList();
  }

  bool isSongFavorite(String songId) => favoriteIds.contains(songId);

  LibraryState copyWith({
    List<Song>? importedSongs,
    bool? scanDone,
    Set<String>? favoriteIds,
    bool? nasImporting,
    int? nasImportedCount,
    Object? nasImportError = _unset,
  }) {
    return LibraryState(
      importedSongs: importedSongs ?? this.importedSongs,
      scanDone: scanDone ?? this.scanDone,
      favoriteIds: favoriteIds ?? this.favoriteIds,
      nasImporting: nasImporting ?? this.nasImporting,
      nasImportedCount: nasImportedCount ?? this.nasImportedCount,
      nasImportError:
          identical(nasImportError, _unset) ? this.nasImportError : nasImportError as String?,
    );
  }
}

class LibraryNotifier extends Notifier<LibraryState> {
  bool _isScanning = false;

  /// 来源过滤开关变化后刷新曲库（allSongs 是 getter，需重建 state 触发监听）
  void refreshSources() => state = state.copyWith();

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

  /// App 启动时恢复上次持久化的曲库（在系统扫描前调用，
  /// 后续 discoverSongs 增量合并不丢失这些歌曲）。
  void restoreCachedSongs(List<Song> songs) {
    if (songs.isEmpty) return;
    state = state.copyWith(
      importedSongs: [...songs, ...state.importedSongs],
      scanDone: true,
    );
  }

  Future<bool> discoverSongs() async {
    if (_isScanning) return false;
    _isScanning = true;
    try {
      final songRepo = ref.read(songRepositoryProvider);
      // 只扫系统音乐库（Android MediaStore / iOS MPMediaQuery）。
      // 沙盒文件由 Pick Files 覆盖（文件已在 app 目录内时直接收录，不重复拷贝），
      // 避免与发现歌曲语义重叠。
      final scannedSongs = await songRepo.scanMediaStore();

      // 按 path 去重（扫描结果内部）
      final seen = <String>{};
      scannedSongs.retainWhere((s) {
        if (s.path == null) return true;
        return seen.add(s.path!);
      });

      if (scannedSongs.isEmpty) return false;

      // 合并到已有列表：已有歌曲保持原位置（扫描到同 path 的新版就地替换），
      // 扫描到的新歌追加到末尾——保证重启/重复扫描后排序稳定。
      final byPath = {
        for (final s in scannedSongs)
          if (s.path != null) s.path!: s,
      };
      final merged = <Song>[];
      final mergedPaths = <String>{};
      for (final s in state.importedSongs) {
        final p = s.path;
        if (p != null && byPath.containsKey(p)) {
          // 同 path 扫描到新版本：就地替换，保持位置
          merged.add(byPath[p]!);
          mergedPaths.add(p);
        } else {
          // 未被替换的已有歌曲（含 NAS 索引 path==null 的歌）原样保留
          merged.add(s);
          if (p != null) mergedPaths.add(p);
        }
      }
      // 追加扫描到的新歌（已有列表没有的 path）
      for (final s in scannedSongs) {
        if (s.path == null || !mergedPaths.contains(s.path)) {
          merged.add(s);
        }
      }

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
        ...state.importedSongs.where(
          (s) => s.path == null || !newPaths.contains(s.path),
        ),
        ...songs,
      ];
      state = state.copyWith(importedSongs: merged);
      songRepo.setCachedSongs(merged);
      onSongsLoaded?.call();
      return true;
    } finally {
      _isScanning = false;
    }
  }

/// 取消 NAS 后台导入（下次扫描批次检查到此标志即中止）
bool _nasImportCancelled = false;

void cancelNasImport() {
  _nasImportCancelled = true;
  state = state.copyWith(nasImporting: false);
}

/// 触发 NAS 后台导入（fire-and-forget，不阻塞调用方），立即返回。
/// 若未连接则用已保存的配置补连；进度经 onBatch 增量入库并更新曲库 UI。
void startNasImport(String sharePath) {
  _nasImportCancelled = false;
  unawaited(_runNasImport(sharePath));
}

Future<void> _runNasImport(String sharePath) async {
  if (_isScanning) return;
  state = state.copyWith(nasImporting: true, nasImportedCount: 0, nasImportError: null);
  try {
    if (!SmbService.isConnected) {
      final prefs = PreferencesService.instance;
      final host = prefs.nasHost;
      if (host == null || host.isEmpty) {
        throw const FormatException('NAS host not configured');
      }
      final ok = await SmbService.connect(
        host: host,
        username: prefs.nasUsername ?? '',
        password: prefs.nasPassword,
      );
      if (!ok) {
        state = state.copyWith(
          nasImporting: false,
          nasImportError: SmbService.lastError ?? 'NAS connection failed',
        );
        return;
      }
    }
    await scanSmb(sharePath);
    state = state.copyWith(nasImporting: false);
  } on NASImportCancelled {
    // 用户主动取消，静默结束
  } catch (e) {
    debugPrint('[Library] NAS import failed: $e');
    state = state.copyWith(nasImporting: false, nasImportError: '$e');
  } finally {
    onSongsLoaded?.call();
  }
}

Future<bool> scanSmb(String sharePath) async {
  if (_isScanning) return false;
  _isScanning = true;
  state = state.copyWith(nasImporting: true);
  try {
    final songRepo = ref.read(songRepositoryProvider);
    // 增量合并：每批下载完立即入库+持久化，
    // UI 实时可见、中途退出也保留已扫部分
    final songs = await songRepo.scanSmb(sharePath, onBatch: (batch) {
      if (_nasImportCancelled) {
        throw const NASImportCancelled();
      }
      state = state.copyWith(
        importedSongs: _mergeById(batch),
        nasImportedCount: state.nasImportedCount + batch.length,
      );
      songRepo.setCachedSongs(state.importedSongs);
      onSongsLoaded?.call();
    });
    // 注意：scanSmb 内部吞掉单文件失败；此处正常只可能因取消抛出
    if (songs.isEmpty) return false;
    // 最终一致性合并（与增量幂等），保证返回值统计准确
    final merged = _mergeById(songs);
    state = state.copyWith(importedSongs: merged);
    songRepo.setCachedSongs(merged);
    onSongsLoaded?.call();
    // 兜底：扫描完成后对仍未拿到封面的 NAS 歌再提取一次
    // （扫描中异步提取可能因取消/批次边界遗漏）
    final pendingCovers = state.importedSongs
        .where((s) =>
            s.smbPath != null && s.path == null && s.coverUrl == null)
        .toList();
    if (pendingCovers.isNotEmpty) {
      unawaited(_extractNasCovers(pendingCovers));
    }
    return true;
  } finally {
    _isScanning = false;
    state = state.copyWith(nasImporting: false);
  }
}

  /// NAS 远端封面批量提取（限流并发 8），完成后刷新 UI。
  /// 失败静默：封面保持纯色占位，不影响曲库。
  Future<void> _extractNasCovers(List<Song> songs) async {
    const batchSize = 8;
    for (var i = 0; i < songs.length; i += batchSize) {
      final end = i + batchSize > songs.length ? songs.length : i + batchSize;
      await Future.wait(
        songs.sublist(i, end).map((s) => SmbService.fetchRemoteCover(s)),
      );
    }
    // 封面就绪（Song.coverUrl 可变字段），触发一次刷新
    state = state.copyWith(
      importedSongs: List<Song>.from(state.importedSongs),
    );
  }

  /// 按歌曲 id 去重合并传入歌曲与现有曲库，保持已有顺序、新歌追加。
  /// NAS 索引歌曲 path 为 null，用 id（如 `smb_<hash>`）保证幂等，
  /// 避免跨批次重复入库；并发批次顺序不稳定时也不会打乱已有顺序。
  List<Song> _mergeById(List<Song> incoming) {
    final seen = <String>{};
    final out = <Song>[];
    for (final s in [...state.importedSongs, ...incoming]) {
      if (seen.add(s.id)) out.add(s);
    }
    return out;
  }

  Future<void> batchExtractCovers(List<Song> songs) async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/.covers');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

    // 待处理的歌曲（无封面缓存、本地文件真实存在）。
    // 不依赖 hasCover 标记（_fileToSong 降级导入时未设）；
    // NAS 缓存路径的本地文件可能已被清理/未下载 → 跳过，
    // 避免 lofty 读取不存在的文件（No such file or directory）。
    final pending = <Song>[];
    for (final s in songs) {
      if (s.path == null || s.coverUrl != null) continue;
      if (!await File(s.path!).exists()) continue;
      pending.add(s);
    }
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
