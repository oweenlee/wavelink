import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';

import 'package:wavelink_mobile/data/services/import_service.dart';
import 'package:wavelink_mobile/data/services/log.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/data/services/rust_service.dart';
import 'package:wavelink_mobile/ui/core/app.dart';
import 'package:wavelink_mobile/ui/core/widgets/mini_player_bar.dart';
import 'package:wavelink_mobile/ui/core/widgets/song_tile.dart';
import 'package:wavelink_mobile/ui/features/library/view_models/library_provider.dart';
import 'package:wavelink_mobile/ui/features/playback/view_models/playback_controller.dart';

/// App Store 截图抓取（模拟器）。
///
/// 与「宿主抓屏」配合：本测试负责把界面导航到目标屏，然后写一个
/// `Documents/.cap_ready_<tag>` 标记并等待宿主写回 `Documents/.cap_done_<tag>`。
/// 宿主（tools/sim_capture.sh）看到 ready 后用 `xcrun simctl io screenshot` 抓真实屏幕，
/// 再写 done 放行。这样拿到的是模拟器原生分辨率截图，且不依赖 flutter_driver 通道。
///
/// 运行：flutter test integration_test/capture_screens_test.dart -d <udid>
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('capture app store screens', (tester) async {
    late Directory docs;
    Future<void> sync(String tag) async {
      final ready = File('${docs.path}/.shotreq_$tag');
      final done = File('${docs.path}/.shotack_$tag');
      if (done.existsSync()) done.deleteSync();
      ready.writeAsStringSync('$tag');
      final sw = Stopwatch()..start();
      while (!done.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (sw.elapsed > const Duration(seconds: 40)) {
          throw StateError('宿主未响应抓屏标记: $tag');
        }
      }
      try {
        done.deleteSync();
        ready.deleteSync();
      } catch (_) {}
    }

    await Log.init();
    await PreferencesService.init();
    await initRust();
    docs = await getApplicationDocumentsDirectory();
    // ignore: avoid_print
    print('DOCS=${docs.path}');

    // 1) 等宿主把零版权演示 FLAC 放进 Documents/Imported
    await sync('seed');

    final songs = await ImportService.scanDocuments();
    // ignore: avoid_print
    print('SEED songs=${songs.length}');

    final container = ProviderContainer();
    container.read(libraryProvider.notifier).restoreCachedSongs(songs);
    container.read(playbackControllerProvider).bootstrap();

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const WaveLinkApp(),
      ),
    );

    Future<void> settle([int ms = 900]) async {
      await tester.pump(Duration(milliseconds: ms));
      await Future<void>.delayed(Duration(milliseconds: ms));
      await tester.pump(Duration(milliseconds: 300));
    }

    await settle(2500);

    Future<void> tapText(String t) async {
      final f = find.text(t);
      if (f.evaluate().isEmpty) {
        // ignore: avoid_print
        print('MISS text=$t');
        return;
      }
      await tester.tap(f.first);
      await settle();
    }

    Future<void> shot(String tag) async {
      // ignore: avoid_print
      print('SHOT $tag @${DateTime.now().toIso8601String()}');
      await sync(tag);
    }

    // 先把分栏固定到 Songs（避免上次选中状态影响首图）
    await tapText('Songs');

    // 01 Songs
    await shot('01_songs');

    // 02 Albums
    await tapText('Albums');
    await shot('02_albums');

    // 03 Artists
    await tapText('Artists');
    await shot('03_artists');

    // 回 Songs
    await tapText('Songs');

    // 04 播放第一首 → 迷你条
    final tiles = find.byType(SongTile);
    if (tiles.evaluate().isEmpty) {
      // ignore: avoid_print
      print('NO SONG TILE — 跳过播放页');
      return;
    }
    await tester.tap(tiles.first);
    await settle(1800);

    // 05 Now Playing（点迷你条）
    final mini = find.byType(MiniPlayerBar);
    if (mini.evaluate().isEmpty) {
      // ignore: avoid_print
      print('NO MINI PLAYER — 跳过 Now Playing');
    } else {
      await tester.tap(mini.first);
      await settle(2200);
      await shot('05_now_playing');

      // 退出 Now Playing：先试系统返回手势，再试返回图标 / 关闭图标
      var popped = false;
      try {
        await tester.pageBack();
        await settle(900);
        popped = true;
      } catch (_) {}
      if (!popped) {
        for (final icon in [
          LucideIcons.chevronDown,
          LucideIcons.chevronLeft,
          LucideIcons.arrowLeft,
          LucideIcons.x,
        ]) {
          final f = find.byIcon(icon);
          if (f.evaluate().isNotEmpty) {
            await tester.tap(f.first);
            await settle(900);
            popped = true;
            break;
          }
        }
      }
      // ignore: avoid_print
      print('POPPED=$popped');
    }

    // 06 Settings
    final settingsIcon = find.byIcon(LucideIcons.settings);
    if (settingsIcon.evaluate().isNotEmpty) {
      await tester.tap(settingsIcon.last);
      await settle(1500);
      await shot('06_settings');
    } else {
      // ignore: avoid_print
      print('NO SETTINGS ICON');
    }

    // ignore: avoid_print
    print('CAPTURE DONE');
  });
}
