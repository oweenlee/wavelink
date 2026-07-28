import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../domain/models/song.dart';
import '../features/library/views/library_page.dart';
import '../features/library/views/search_page.dart';
import '../features/settings/views/settings_page.dart';
import '../features/playback/views/now_playing_page.dart';
import '../features/library/views/album_detail_page.dart';
import '../features/library/views/artist_detail_page.dart';
import '../features/library/views/song_list_page.dart';
import '../features/settings/views/diagnostic_page.dart';
import '../features/library/views/import_page.dart';
import 'app.dart';

final goRouter = GoRouter(
  initialLocation: '/library',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: LibraryPage(),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: SearchPage(),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: SettingsPage(),
              ),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/now-playing',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const NowPlayingPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      ),
    ),
    GoRoute(
      path: '/album',
      builder: (context, state) {
        final album = state.extra as Album;
        return AlbumDetailPage(album: album);
      },
    ),
    GoRoute(
      path: '/artist',
      builder: (context, state) {
        final args = state.extra as Map<String, dynamic>;
        return ArtistDetailPage(
          artistName: args['name'] as String,
          artistColor: args['color'] as Color,
        );
      },
    ),
    GoRoute(
      path: '/song-list',
      builder: (context, state) {
        final args = state.extra as Map<String, dynamic>;
        return SongListPage(
          title: args['title'] as String,
          songs: args['songs'] as List<Song>,
          accentColor: args['accentColor'] as Color,
          isFavoriteList: args['isFavoriteList'] as bool,
        );
      },
    ),
    GoRoute(
      path: '/diagnostic',
      builder: (context, state) => const DiagnosticPage(),
    ),
    GoRoute(
      path: '/import',
      builder: (context, state) => const ImportPage(),
    ),
  ],
);
