import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../data/services/webdav_service.dart';
import '../../../../domain/models/song.dart';
import '../../../core/providers/repositories.dart';
import '../../playback/view_models/queue_provider.dart';
import 'cover_service.dart';
import '../../../../data/services/log.dart';

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

  /// 音乐服务器（Subsonic）扫描失败信息（空表示无错误）
  final String? subsonicError;

  /// WebDAV 音乐源扫描失败信息（空表示无错误）
  final String? webdavError;

  const LibraryState({
    this.importedSongs = const [],
    this.scanDone = false,
    this.favoriteIds = const {},
    this.nasImporting = false,
    this.nasImportedCount = 0,
    this.nasImportError,
    this.subsonicError,
    this.webdavError,
  });

  /// 曲库可见歌曲：按来源开关过滤（关闭的来源不在曲库展示）。
  /// 队列/收藏/播放不受影响（各自独立数据源）。
  /// 队列/收藏/播放不受影响（各自独立数据源）。
  List<Song> get allSongs {
    final prefs = PreferencesService.instance;
    return importedSongs.where((s) => prefs.showSource(s.source)).toList();
  }

  bool isSongFavorite(String songId) => favoriteIds.contains(songId);

  LibraryState copyWith({
    List<Song>? importedSongs,
    bool? scanDone,
    Set<String>? favoriteIds,
    bool? nasImporting,
    int? nasImportedCount,
    Object? nasImportError = _unset,
    Object? subsonicError = _unset,
    Object? webdavError = _unset,
  }) {
    return LibraryState(
      importedSongs: importedSongs ?? this.importedSongs,
      scanDone: scanDone ?? this.scanDone,
      favoriteIds: favoriteIds ?? this.favoriteIds,
      nasImporting: nasImporting ?? this.nasImporting,
      nasImportedCount: nasImportedCount ?? this.nasImportedCount,
      nasImportError: identical(nasImportError, _unset)
          ? this.nasImportError
          : nasImportError as String?,
      subsonicError: identical(subsonicError, _unset)
          ? this.subsonicError
          : subsonicError as String?,
      webdavError: identical(webdavError, _unset)
          ? this.webdavError
          : webdavError as String?,
    );
  }
}

class LibraryNotifier extends Notifier<LibraryState> {
  bool _isScanning = false;

  /// 封面提取调度（拆分自本类）：完成后回调刷新 UI 并持久化
  late final CoverService _covers = CoverService(
    ref,
    onCoversUpdated: _onCoversUpdated,
  );

  /// 封面就绪：Song.coverUrl 是可变字段，重建列表触发 UI 刷新，
  /// 并落盘，否则重启后曲库恢复时封面全部丢失。
  void _onCoversUpdated() {
    // 封面提取是异步 fire-and-forget，测试/生命周期切换时容器可能已
    // dispose，此时再写 state 会抛 "Ref after it has been disposed"
    if (!ref.mounted) return;
    state = state.copyWith(importedSongs: List<Song>.from(state.importedSongs));
    ref.read(songRepositoryProvider).setCachedSongs(state.importedSongs);
  }

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
  /// 持久化已改为相对路径（LibraryCacheService），容器变更不再影响；
  /// 此处存在性清洗仅兜底：缓存被系统清理、存量旧绝对路径数据。
  void restoreCachedSongs(List<Song> songs) {
    if (songs.isEmpty) return;
    for (final s in songs) {
      // 封面文件已不存在（缓存被清/存量旧数据）→ 置空走下方补提取
      if (s.coverUrl != null && !File(s.coverUrl!).existsSync()) {
        s.coverUrl = null;
      }
      // 本地文件已不存在：SMB 歌置空 path 回到按需下载模式；
      // 其他来源无法自恢复，同样置空避免后续拿着死路径去解析。
      // URL 型路径（ipod-library:// 等）不做存在性检查
      if (s.path != null &&
          !s.path!.contains('://') &&
          !File(s.path!).existsSync()) {
        s.path = null;
      }
    }
    state = state.copyWith(
      importedSongs: [...songs, ...state.importedSongs],
      scanDone: true,
    );
    // NAS 索引歌（无本地文件）：远端读头重提取封面
    final pendingCovers = CoverService.pendingNasCovers(state.importedSongs);
    if (pendingCovers.isNotEmpty) {
      unawaited(_covers.extractNasCovers(pendingCovers));
    }
    // 有本地文件的歌（离线缓存/本地导入）：从文件重提取封面
    final localPending = CoverService.pendingLocalCovers(state.importedSongs);
    if (localPending.isNotEmpty) {
      unawaited(_covers.extractLocalCovers(localPending));
    }
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
      // 用 id 去重合并（与 NAS _mergeById 一致）：Subsonic 的 path 是
      // server-local 路径，与本地/NAS 路径不互通，按 path 差集去重会
      // 顺序重置甚至重复累积；id（sub_<serverId>）服务端稳定。
      final merged = _mergeById(songs);
      state = state.copyWith(importedSongs: merged, subsonicError: null);
      songRepo.setCachedSongs(merged);
      // 服务器已删歌曲清理：仅扫描成功完成后执行（失败/空库走下方
      // 分支不触达，避免掉线时误删曲库条目与收藏）。
      if (songs.isNotEmpty) _pruneSubsonicRemoved(songs);
      onSongsLoaded?.call();
      return songs.isNotEmpty;
    } catch (e) {
      Log.e('Library', 'Subsonic scan failed: $e');
      state = state.copyWith(subsonicError: '$e');
      return false;
    } finally {
      _isScanning = false;
    }
  }

  /// 扫描 WebDAV 音乐源并入库。增量批次实时合并（onBatch），
  /// 完成后再整体合并 + 服务器已删歌曲清理。失败返回 false 并
  /// 置 [LibraryState.webdavError]，与「服务器真空库返回 true」可区分。
  Future<bool> scanWebdav() async {
    if (_isScanning) return false;
    _isScanning = true;
    try {
      final songRepo = ref.read(songRepositoryProvider);
      final songs = await songRepo.scanWebdav(
        onBatch: (batch) {
          state = state.copyWith(importedSongs: _mergeById(batch));
          songRepo.setCachedSongs(state.importedSongs);
          Log.d(
            'Library',
            'WebDAV 增量入库 +${batch.length} 首'
                '（曲库共 ${state.importedSongs.length}）',
          );
          onSongsLoaded?.call();
        },
      );
      final merged = _mergeById(songs);
      state = state.copyWith(importedSongs: merged, webdavError: null);
      songRepo.setCachedSongs(merged);
      // 服务器已删歌曲清理：仅扫描成功完成后执行（失败/空库不触达）
      if (songs.isNotEmpty) _pruneWebdavRemoved(songs);
      // 兜底：扫描完成后对仍未拿到封面的 WebDAV 歌再提取一次
      //（与 NAS 导入对齐；onBatch 仅增量合并不触发提取，缺此会永不提封面）
      final pendingCovers = CoverService.pendingNasCovers(state.importedSongs);
      if (pendingCovers.isNotEmpty) {
        unawaited(_covers.extractNasCovers(pendingCovers));
      }
      Log.i(
        'Library',
        'WebDAV 入库完成：扫描 ${songs.length} 首，'
            '曲库共 ${state.importedSongs.length} 首',
      );
      onSongsLoaded?.call();
      return songs.isNotEmpty;
    } catch (e) {
      Log.e('Library', 'WebDAV scan failed: $e');
      state = state.copyWith(webdavError: '$e');
      return false;
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
    state = state.copyWith(
      nasImporting: true,
      nasImportedCount: 0,
      nasImportError: null,
    );
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
      Log.e('Library', 'NAS import failed: $e');
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
      final songs = await songRepo.scanSmb(
        sharePath,
        onBatch: (batch) {
          if (_nasImportCancelled) {
            throw const NASImportCancelled();
          }
          state = state.copyWith(
            importedSongs: _mergeById(batch),
            nasImportedCount: state.nasImportedCount + batch.length,
          );
          songRepo.setCachedSongs(state.importedSongs);
          onSongsLoaded?.call();
        },
      );
      // 注意：scanSmb 内部吞掉单文件失败；此处正常只可能因取消抛出
      if (songs.isEmpty) return false;
      // 最终一致性合并（与增量幂等），保证返回值统计准确
      final merged = _mergeById(songs);
      state = state.copyWith(importedSongs: merged);
      songRepo.setCachedSongs(merged);
      onSongsLoaded?.call();
      // NAS 同步：清理 NAS 上已删除的歌曲（仅扫描成功完成后执行；
      // 中途取消/失败走异常分支不会触达这里）
      _pruneNasRemoved(sharePath, songs);
      // 兜底：扫描完成后对仍未拿到封面的 NAS 歌再提取一次
      // （扫描中异步提取可能因取消/批次边界遗漏）
      final pendingCovers = CoverService.pendingNasCovers(state.importedSongs);
      if (pendingCovers.isNotEmpty) {
        unawaited(_covers.extractNasCovers(pendingCovers));
      }
      return true;
    } finally {
      _isScanning = false;
      state = state.copyWith(nasImporting: false);
    }
  }

  /// 本地文件封面批量提取（对外入口，委托 [CoverService]）
  Future<void> batchExtractCovers(List<Song> songs) =>
      _covers.extractLocalCovers(songs);

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

  /// 从曲库删除歌曲：移除条目并同步清理收藏；属于 App 沙盒内的
  /// 物理文件（Imported/ 导入副本、.smb_cache/ NAS 下载缓存、
  /// .covers/ 封面缓存、歌词文件）一并删除，不留孤儿文件。
  /// 沙盒外文件（系统媒体库）无权删除，仅移除条目——下次
  /// discoverSongs 扫描会重新收录，属预期行为。
  Future<void> removeSong(Song song) async {
    state = state.copyWith(
      importedSongs: state.importedSongs.where((s) => s.id != song.id).toList(),
      favoriteIds: {...state.favoriteIds}..remove(song.id),
    );
    ref.read(songRepositoryProvider).setCachedSongs(state.importedSongs);
    _persistFavorites();
    await _deleteSandboxFiles(song);
  }

  /// 删除歌曲在 App 沙盒内的关联文件（Imported/ 导入副本、.smb_cache/
  /// NAS 下载缓存、.webdav_cache/ WebDAV 下载缓存、.covers/ 封面缓存、
  /// 歌词文件），不留孤儿文件；沙盒外文件（系统媒体库）无权删除，仅跳过。
  Future<void> _deleteSandboxFiles(Song song) async {
    final appDir = await getApplicationDocumentsDirectory();
    final sandboxPrefix = '${appDir.path}/';
    for (final p in [
      song.path,
      song.coverUrl,
      song.lyricsPath,
      // NAS 远端歌词的本地缓存（.lrc_cache/）
      if (song.smbPath != null && song.smbPath!.isNotEmpty)
        '${appDir.path}/.lrc_cache/${song.smbPath.hashCode}.lrc',
      // WebDAV 下载缓存（{davPath.hashCode}_{name}，与 webdav_service 命名一致）
      if (song.davPath != null && song.davPath!.isNotEmpty)
        '${appDir.path}/.webdav_cache/${song.davPath!.hashCode}_${song.davPath!.split('/').last}',
    ]) {
      if (p == null || !p.startsWith(sandboxPrefix)) continue;
      final f = File(p);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (e) {
          Log.e('Library', '清理缓存文件失败: $p ($e)');
        }
      }
    }
  }

  /// NAS 同步清理：把 NAS 上已不存在的歌曲移出曲库（含收藏），并异步
  /// 删除其沙盒缓存文件（下载副本/封面/歌词）。仅处理 smbPath 前缀匹配
  /// 本次扫描目录的 NAS 歌——换目录/子集扫描时保守保留，杜绝误删；
  /// 本地导入与系统媒体库歌曲不受影响。
  void _pruneNasRemoved(String sharePath, List<Song> scanned) {
    final root = sharePath.split('/').skip(1).join('/');
    // root 为空（扫描 share 根目录）时全部 NAS 歌参与比对
    bool inRoot(String p) =>
        root.isEmpty || p == root || p.startsWith('$root/');
    final livePaths = {
      for (final s in scanned)
        if (s.smbPath != null) s.smbPath!,
    };
    final gone = state.importedSongs
        .where(
          (s) =>
              s.smbPath != null &&
              inRoot(s.smbPath!) &&
              !livePaths.contains(s.smbPath),
        )
        .toList();
    if (gone.isEmpty) return;
    final goneIds = {for (final s in gone) s.id};
    state = state.copyWith(
      importedSongs: state.importedSongs
          .where((s) => !goneIds.contains(s.id))
          .toList(),
      favoriteIds: {...state.favoriteIds}..removeAll(goneIds),
    );
    ref.read(songRepositoryProvider).setCachedSongs(state.importedSongs);
    _persistFavorites();
    Log.i('Library', 'NAS 同步：移除 ${gone.length} 首 NAS 已删除的歌曲');
    unawaited(Future.wait(gone.map(_deleteSandboxFiles)));
  }

  /// 音乐服务器（Subsonic）同步清理：把服务器上已不存在的歌曲移出曲库
  /// （含收藏），仅处理 id 前缀为 sub_ 的歌；本地/导入/NAS 歌不受影响。
  /// 仅扫描成功完成后执行，失败路径不触达，避免掉线时误删。
  void _pruneSubsonicRemoved(List<Song> scanned) {
    final liveIds = {for (final s in scanned) s.id};
    final gone = state.importedSongs
        .where((s) => s.id.startsWith('sub_') && !liveIds.contains(s.id))
        .toList();
    if (gone.isEmpty) return;
    final goneIds = {for (final s in gone) s.id};
    state = state.copyWith(
      importedSongs: state.importedSongs
          .where((s) => !goneIds.contains(s.id))
          .toList(),
      favoriteIds: {...state.favoriteIds}..removeAll(goneIds),
    );
    ref.read(songRepositoryProvider).setCachedSongs(state.importedSongs);
    _persistFavorites();
    Log.i('Library', 'Subsonic 同步：移除 ${gone.length} 首服务器已删除的歌曲');
  }

  /// WebDAV 同步清理：把服务器上已不存在的歌曲移出曲库（含收藏），并异步
  /// 删除其本地下载缓存。仅处理 davPath 前缀匹配本次扫描根目录的歌——
  /// 换目录/子集扫描时保守保留，杜绝误删；其他来源歌曲不受影响。
  /// 仅扫描成功完成后执行，失败/空库路径不触达，避免掉线时误删。
  void _pruneWebdavRemoved(List<Song> scanned) {
    final root = WebdavService.rootPath ?? '';
    // root 为空（扫描服务器根目录）时全部 WebDAV 歌参与比对
    bool inRoot(String p) =>
        root.isEmpty || p == root || p.startsWith('$root/');
    final livePaths = {
      for (final s in scanned)
        if (s.davPath != null) s.davPath!,
    };
    final gone = state.importedSongs
        .where(
          (s) =>
              s.davPath != null &&
              inRoot(s.davPath!) &&
              !livePaths.contains(s.davPath),
        )
        .toList();
    if (gone.isEmpty) return;
    final goneIds = {for (final s in gone) s.id};
    state = state.copyWith(
      importedSongs: state.importedSongs
          .where((s) => !goneIds.contains(s.id))
          .toList(),
      favoriteIds: {...state.favoriteIds}..removeAll(goneIds),
    );
    ref.read(songRepositoryProvider).setCachedSongs(state.importedSongs);
    _persistFavorites();
    Log.i('Library', 'WebDAV 同步：移除 ${gone.length} 首服务器已删除的歌曲');
    unawaited(Future.wait(gone.map(_deleteSandboxFiles)));
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
