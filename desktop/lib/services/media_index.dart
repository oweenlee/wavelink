import '../models/track.dart';

/// 派生自曲库的「专辑」聚合单元。
///
/// [key] 采用 `artist\u0000album` 防重名主键，避免不同艺人同名专辑被合并
/// （对齐 MediaMonkey「Multiple Artist Albums」、Apple Music「Other Versions」思路）。
class AlbumGroup {
  final String key;
  final String name;
  final String artist;
  final List<Track> tracks;
  final String? coverUrl;

  const AlbumGroup({
    required this.key,
    required this.name,
    required this.artist,
    required this.tracks,
    this.coverUrl,
  });

  /// 曲目按专辑内音轨号排序（无音轨号沉底、其间保持原序）。
  List<Track> get orderedTracks {
    final sorted = [...tracks];
    sorted.sort((a, b) {
      final na = a.trackNumber ?? 0;
      final nb = b.trackNumber ?? 0;
      if (na == 0 && nb == 0) return 0;
      if (na == 0) return 1;
      if (nb == 0) return -1;
      return na.compareTo(nb);
    });
    return sorted;
  }
}

/// 派生自曲库的「艺术家」聚合单元。
class ArtistGroup {
  final String name;
  final List<Track> tracks;
  final List<AlbumGroup> albums;

  const ArtistGroup({
    required this.name,
    required this.tracks,
    required this.albums,
  });

  /// 代表性封面：优先取首个有封面的专辑，否则取首曲封面。
  String? get coverUrl {
    for (final a in albums) {
      if (a.coverUrl != null && a.coverUrl!.isNotEmpty) return a.coverUrl;
    }
    for (final t in tracks) {
      if (t.coverUrl != null && t.coverUrl!.isNotEmpty) return t.coverUrl;
    }
    return null;
  }
}

/// 媒体索引（艺术家 / 专辑视图的纯派生数据层）。
///
/// 从 [PlayerController.library]（每次增删 / 封面回填都会换新引用的列表）派生，
/// 自身不持有任何可变状态。基于 library 列表引用做单条目缓存：封面批量回填时
/// 至多重建几十次，开销可忽略。视图层只读不写，可安全共享同一实例。
class MediaIndex {
  static MediaIndex? _cache;
  static List<Track>? _cacheLib;

  final List<ArtistGroup> artists;
  final List<AlbumGroup> albums;

  MediaIndex._(this.artists, this.albums);

  factory MediaIndex.build(List<Track> library) {
    if (_cache != null && identical(_cacheLib, library)) return _cache!;
    final artists = _aggregateArtists(library);
    final albums = _aggregateAlbums(library);
    final idx = MediaIndex._(artists, albums);
    _cache = idx;
    _cacheLib = library;
    return idx;
  }

  static const String _sep = '\u0000';

  static List<AlbumGroup> _aggregateAlbums(List<Track> library) {
    final map = <String, List<Track>>{};
    for (final t in library) {
      final artist = t.artist;
      final album = t.album ?? '';
      final key = '$artist$_sep$album';
      (map[key] ??= []).add(t);
    }
    final groups = map.entries.map((e) {
      final parts = e.key.split(_sep);
      final cover = e.value
          .where((t) => t.coverUrl != null && t.coverUrl!.isNotEmpty)
          .map((t) => t.coverUrl!)
          .firstOrNull;
      return AlbumGroup(
        key: e.key,
        name: parts[1],
        artist: parts[0],
        tracks: e.value,
        coverUrl: cover,
      );
    }).toList();
    groups.sort((a, b) => a.name.compareTo(b.name));
    return groups;
  }

  static List<ArtistGroup> _aggregateArtists(List<Track> library) {
    final map = <String, List<Track>>{};
    for (final t in library) {
      (map[t.artist] ??= []).add(t);
    }
    final groups = map.entries.map((e) {
      final artist = e.key;
      final albumMap = <String, List<Track>>{};
      for (final t in e.value) {
        final album = t.album ?? '';
        final key = '$artist$_sep$album';
        (albumMap[key] ??= []).add(t);
      }
      final albums = albumMap.entries.map((ae) {
        final cover = ae.value
            .where((t) => t.coverUrl != null && t.coverUrl!.isNotEmpty)
            .map((t) => t.coverUrl!)
            .firstOrNull;
        return AlbumGroup(
          key: ae.key,
          name: ae.value.first.album ?? '',
          artist: artist,
          tracks: ae.value,
          coverUrl: cover,
        );
      }).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      return ArtistGroup(name: artist, tracks: e.value, albums: albums);
    }).toList();
    groups.sort((a, b) => a.name.compareTo(b.name));
    return groups;
  }

  // —— 过滤 / 排序辅助（0 = 名称，1 = 数量） ——

  static List<ArtistGroup> filterArtists(
      List<ArtistGroup> list, String query) {
    if (query.isEmpty) return list;
    final q = query.toLowerCase();
    return list.where((a) => a.name.toLowerCase().contains(q)).toList();
  }

  static List<ArtistGroup> sortArtists(List<ArtistGroup> list, int sort) {
    final l = [...list];
    l.sort((a, b) => sort == 1
        ? b.tracks.length.compareTo(a.tracks.length)
        : a.name.compareTo(b.name));
    return l;
  }

  static List<AlbumGroup> filterAlbums(List<AlbumGroup> list, String query) {
    if (query.isEmpty) return list;
    final q = query.toLowerCase();
    return list
        .where((a) =>
            a.name.toLowerCase().contains(q) ||
            a.artist.toLowerCase().contains(q))
        .toList();
  }

  static List<AlbumGroup> sortAlbums(List<AlbumGroup> list, int sort) {
    final l = [...list];
    l.sort((a, b) => sort == 1
        ? b.tracks.length.compareTo(a.tracks.length)
        : a.name.compareTo(b.name));
    return l;
  }

  ArtistGroup? artistByName(String name) =>
      artists.where((a) => a.name == name).firstOrNull;
  AlbumGroup? albumByKey(String key) =>
      albums.where((a) => a.key == key).firstOrNull;
}
