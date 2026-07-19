import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/playback_provider.dart';
import '../theme/app_theme.dart';
import '../models/song.dart';
import '../services/preferences_service.dart';
import '../widgets/song_tile.dart';
import 'album_detail_page.dart';
import 'artist_detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';
  List<String> get _history => PreferencesService.instance.searchHistory;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commitQuery() {
    final q = _controller.text.trim();
    if (q.isNotEmpty) {
      PreferencesService.instance.addSearchHistory(q);
      setState(() {});
    }
  }

  List<MapEntry<String, List<Song>>> get _results {
    if (_query.isEmpty) return [];
    final q = _query.toLowerCase();
    final player = context.read<PlaybackProvider>();
    final songs = player.allSongs;

    final matched = songs.where((s) =>
        s.title.toLowerCase().contains(q) ||
        s.artist.toLowerCase().contains(q) ||
        s.album.toLowerCase().contains(q)).toList();

    final albumNames = matched.map((s) => s.album).toSet();
    final artistNames = matched.map((s) => s.artist).toSet();

    final result = <MapEntry<String, List<Song>>>[];
    if (matched.isNotEmpty) result.add(MapEntry('歌曲', matched));
    if (albumNames.isNotEmpty) {
      result.add(MapEntry('专辑', albumNames.map((name) =>
          matched.firstWhere((s) => s.album == name)).toList()));
    }
    if (artistNames.isNotEmpty) {
      result.add(MapEntry('艺术家', artistNames.map((name) =>
          matched.firstWhere((s) => s.artist == name)).toList()));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppTheme.surfaceDark.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            onChanged: (v) {
              setState(() => _query = v);
              if (v.trim().isNotEmpty) _commitQuery();
            },
            style: const TextStyle(fontSize: 16, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: '搜索歌曲、专辑、艺术家',
              hintStyle: const TextStyle(
                fontSize: 16,
                color: AppTheme.textTertiary,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: AppTheme.textTertiary,
                size: 22,
              ),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.textTertiary,
                        size: 18,
                      ),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _query.isEmpty ? _buildHistory() : _buildResults()),
      ],
    );
  }

  Widget _buildHistory() {
    final hasSongs = context.watch<PlaybackProvider>().allSongs.isNotEmpty;

    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_rounded,
              size: 48,
              color: AppTheme.textTertiary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              hasSongs ? '搜索你的音乐' : '导入音乐后即可搜索',
              style: const TextStyle(fontSize: 15, color: AppTheme.textTertiary),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '搜索历史',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary,
                ),
              ),
              GestureDetector(
                onTap: () {
                  PreferencesService.instance.clearSearchHistory();
                  setState(() {});
                },
                child: const Text(
                  '清空',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _history.map((h) {
              return GestureDetector(
                onTap: () {
                  _controller.text = h;
                  setState(() => _query = h);
                },
                onLongPress: () {
                  PreferencesService.instance.removeSearchHistory(h);
                  setState(() {});
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceDark.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.textTertiary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 14,
                        color: AppTheme.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        h,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final results = _results;
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: AppTheme.textTertiary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            const Text(
              '未找到结果',
              style: TextStyle(fontSize: 15, color: AppTheme.textTertiary),
            ),
          ],
        ),
      );
    }

    final player = context.watch<PlaybackProvider>();

    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: results.expand((entry) {
        final items = <Widget>[];
        items.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              entry.key,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        );
        if (entry.key == '歌曲') {
          for (final s in entry.value) {
            items.add(
              SongTile(
                song: s,
                isPlaying: player.isPlaying && player.currentSong?.id == s.id,
                onTap: () => player.playSong(s),
              ),
            );
          }
        } else if (entry.key == '专辑') {
          for (final s in entry.value) {
            final albumSongs = player.allSongs.where((x) => x.album == s.album).toList();
            items.add(
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: s.dominantColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                title: Text(
                  s.album,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  s.artist,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: context.read<PlaybackProvider>(),
                      child: AlbumDetailPage(album: Album(
                        id: s.album,
                        title: s.album,
                        artist: s.artist,
                        year: 0,
                        songs: albumSongs,
                        dominantColor: s.dominantColor,
                      )),
                    ),
                  ),
                ),
              ),
            );
          }
        } else {
          for (final s in entry.value) {
            final count = player.allSongs.where((x) => x.artist == s.artist).length;
            items.add(
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: s.dominantColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                title: Text(
                  s.artist,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '$count 首歌曲',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: context.read<PlaybackProvider>(),
                      child: ArtistDetailPage(
                        artistName: s.artist,
                        artistColor: s.dominantColor,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        }
        return items;
      }).toList(),
    );
  }
}
