import 'dart:async';
import '../../domain/models/song.dart';
import '../services/import_service.dart';
import '../services/library_cache_service.dart';

/// 歌曲数据的单一来源
///
/// 封装三种导入渠道（MediaStore / Documents / 文件选择器）
/// 提供歌曲列表的内存缓存，由 ImportService 执行实际扫描
class SongRepository {
  List<Song> _cachedSongs = [];

  List<Song> getCachedSongs() => List.unmodifiable(_cachedSongs);

  void setCachedSongs(List<Song> songs) {
    _cachedSongs = List.from(songs);
    unawaited(LibraryCacheService.saveSongs(songs));
  }

  void addSongs(List<Song> songs) {
    _cachedSongs.addAll(songs);
    unawaited(LibraryCacheService.saveSongs(_cachedSongs));
  }

  void clearCache() {
    _cachedSongs = [];
    unawaited(LibraryCacheService.saveSongs([]));
  }

  // ── 扫描来源 ──

  Future<List<Song>> scanMediaStore() => ImportService.scanMediaStore();

  Future<List<Song>> scanDocuments() => ImportService.scanDocuments();

  Future<List<Song>> scanAll() => ImportService.scanAll();

  Future<List<Song>> pickAndImport() => ImportService.pickAndImport();

  Future<List<Song>> scanSubsonic() => ImportService.scanSubsonic();

  Future<List<Song>> scanSmb(
    String sharePath, {
    void Function(List<Song> batch)? onBatch,
  }) => ImportService.scanSmb(sharePath, onBatch: onBatch);

  /// 封面缓存（委托给 ImportService 的异步缓存方法）
  Future<void> cacheCovers(List<Song> songs) =>
      ImportService.cacheCovers(songs);
}
