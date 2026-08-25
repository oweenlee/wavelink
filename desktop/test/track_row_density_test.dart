import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/core/theme.dart';
import 'package:local_music_player/l10n/app_localizations.dart';
import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/player_providers.dart';
import 'package:local_music_player/widgets/track_row.dart';

Widget _app(Widget child) => ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        theme: buildAppTheme(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AccentScope(
            accent: AppTheme.accentFallback,
            child: child,
          ),
        ),
      ),
    );

void main() {
  testWidgets('TrackRow 紧凑密度行高不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final player = container.read(playerProvider.notifier);

    final tracks = List.generate(
        3,
        (i) => Track(
            id: 't$i',
            title: 'Track title long enough $i',
            artist: 'Artist name $i',
            filePath: '/tmp/t$i.flac',
            durationHint: const Duration(minutes: 4, seconds: 32)));

    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_app(UncontrolledProviderScope(
      container: container,
      child: ListView.builder(
        itemExtent: 48,
        itemCount: tracks.length,
        itemBuilder: (c, i) => TrackRow(
          player: player,
          track: tracks[i],
          index: i,
          isCurrent: i == 1,
          onPlay: (_) {},
        ),
      ),
    )));
    await tester.pump();
    final e = tester.takeException();
    expect(e, isNull, reason: '紧凑密度行溢出: $e');
  });

  testWidgets('TrackRow 舒适密度行高不溢出', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'ui.rowDensity': 'comfortable'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final player = container.read(playerProvider.notifier);

    final tracks = List.generate(
        3,
        (i) => Track(
            id: 't$i',
            title: 'Track title long enough $i',
            artist: 'Artist name $i',
            filePath: '/tmp/t$i.flac',
            durationHint: const Duration(minutes: 4, seconds: 32)));

    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpWidget(_app(UncontrolledProviderScope(
      container: container,
      child: ListView.builder(
        itemExtent: 56,
        itemCount: tracks.length,
        itemBuilder: (c, i) => TrackRow(
          player: player,
          track: tracks[i],
          index: i,
          isCurrent: i == 1,
          onPlay: (_) {},
        ),
      ),
    )));
    await tester.pump();
    final e = tester.takeException();
    expect(e, isNull, reason: '舒适密度行溢出: $e');
  });
}
