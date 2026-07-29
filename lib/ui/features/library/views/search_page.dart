import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../../l10n/app_localizations.dart';
import '../../playback/view_models/playback_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../../domain/models/song.dart';
import '../../../../data/services/preferences_service.dart';
import '../../../core/widgets/song_tile.dart';

enum _ResultKind { songs, albums, artists }

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

  List<( _ResultKind, List<Song>)> get _results {
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

    final result = <( _ResultKind, List<Song>)>[];
    if (matched.isNotEmpty) {
      result.add((_ResultKind.songs, matched));
    }
    if (albumNames.isNotEmpty) {
      result.add((
        _ResultKind.albums,
        albumNames.map((name) => matched.firstWhere((s) => s.album == name)).toList(),
      ));
    }
    if (artistNames.isNotEmpty) {
      result.add((
        _ResultKind.artists,
        artistNames.map((name) => matched.firstWhere((s) => s.artist == name)).toList(),
      ));
    }
    return result;
  }

  String _sectionTitle(AppLocalizations l10n, _ResultKind kind) {
    switch (kind) {
      case _ResultKind.songs:
        return l10n.libSongs;
      case _ResultKind.albums:
        return l10n.libAlbums;
      case _ResultKind.artists:
        return l10n.libArtists;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh.withValues(alpha: 0.6),
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
              hintText: l10n.searchHint,
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
    final l10n = AppLocalizations.of(context);
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
              hasSongs ? l10n.searchYourMusic : l10n.importThenSearch,
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
              Text(
                l10n.searchHistory,
                style: const TextStyle(
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
                child: Text(
                  l10n.clear,
                  style: const TextStyle(
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
    final l10n = AppLocalizations.of(context);
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
            Text(
              l10n.noResults,
              style: const TextStyle(fontSize: 15, color: AppTheme.textTertiary),
            ),
          ],
        ),
      );
    }

    final player = context.watch<PlaybackProvider>();

    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: results.expand((entry) {
        final kind = entry.$1;
        final value = entry.$2;
        final items = <Widget>[];
        items.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              _sectionTitle(l10n, kind),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        );
        if (kind == _ResultKind.songs) {
          for (final s in value) {
            items.add(
              SongTile(
                song: s,
                isPlaying: player.isPlaying && player.currentSong?.id == s.id,
                onTap: () => player.playSong(s),
              ),
            );
          }
        } else if (kind == _ResultKind.albums) {
          for (final s in value) {
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
                onTap: () => context.push('/album', extra: Album(
                  id: s.album,
                  title: s.album,
                  artist: s.artist,
                  year: 0,
                  songs: albumSongs,
                  dominantColor: s.dominantColor,
                )),
              ),
            );
          }
        } else {
          for (final s in value) {
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
                  l10n.songsCount(count),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
                onTap: () => context.push('/artist', extra: {
                  'name': s.artist,
                  'color': s.dominantColor,
                }),
              ),
            );
          }
        }
        return items;
      }).toList(),
    );
  }
}
