import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../domain/models/song.dart';
import '../features/library/views/library_page.dart';
import '../features/settings/views/settings_page.dart';
import '../features/playback/views/now_playing_page.dart';
import '../features/library/views/album_detail_page.dart';
import '../features/library/views/artist_detail_page.dart';
import '../features/library/views/song_list_page.dart';
import '../features/settings/views/diagnostic_page.dart';
import '../features/settings/views/autoeq_settings_page.dart';
import '../features/library/views/nas_settings_page.dart';
import '../features/library/views/subsonic_settings_page.dart';
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
              pageBuilder: (context, state) =>
                  const NoTransitionPage(child: LibraryPage()),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) =>
                  const NoTransitionPage(child: SettingsPage()),
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
        // 上滑卡片入场 + 轻微回弹，对齐主流播放器手感
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final slide = Tween<Offset>(
            begin: const Offset(0, 0.15),
            end: Offset.zero,
          ).animate(curved);
          return SlideTransition(
            position: slide,
            child: FadeTransition(opacity: curved, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 380),
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
    GoRoute(path: '/nas', builder: (context, state) => const NasSettingsPage()),
    GoRoute(
      path: '/subsonic',
      builder: (context, state) => const SubsonicSettingsPage(),
    ),
    GoRoute(
      path: '/autoeq',
      builder: (context, state) => const AutoEqSettingsPage(),
    ),
  ],
);
