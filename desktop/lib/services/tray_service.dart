import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'player_notifier.dart';
import 'player_providers.dart';

/// System tray integration: icon, context menu (show / play-pause / next /
/// quit), and click-to-toggle behaviour.
///
/// `trayManager.setIcon` expects an *asset* path — on macOS the bytes are read
/// from the bundle, on Windows the file is resolved under `data/flutter_assets`,
/// so we just pass the registered asset name.
class TrayService with TrayListener {
  final ProviderContainer container;
  late final PlayerNotifier _player;

  TrayService(this.container) {
    trayManager.addListener(this);
    _player = container.read(playerProvider.notifier);
  }

  Future<void> init() async {
    final asset =
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png';
    await trayManager.setIcon(asset);
    await _buildMenu();

    // Keep the tray menu label in sync with playback state.
    // select 精细订阅：只听 playing / currentTrack，避开 25Hz position 抖动。
    container.listen(
      playerProvider.select((s) => s.playing),
      (_, _) => _buildMenu(),
    );
    container.listen(
      playerProvider.select((s) => s.currentTrack),
      (_, _) => _buildMenu(),
    );
  }

  Future<void> _buildMenu() async {
    final st = container.read(playerProvider);
    final label = st.playing ? '暂停' : '播放';
    final track = st.currentTrack;
    await trayManager.setContextMenu(
      Menu(items: [
        MenuItem(
          key: 'show',
          label: track != null
              ? '${track.artist} - ${track.title}'
              : '本地音乐播放器',
        ),
        MenuItem.separator(),
        MenuItem(key: 'play_pause', label: label),
        MenuItem(key: 'next', label: '下一首'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]),
    );
  }

  @override
  void onTrayIconMouseDown() {
    // Left click: show window if it is hidden.
    windowManager.isVisible().then((visible) {
      if (!visible) {
        windowManager.show();
        windowManager.focus();
      }
    });
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'play_pause':
        _player.togglePlay();
      case 'next':
        _player.next();
      case 'quit':
        unawaited(_quit());
    }
  }

  /// 完整退出：先移除托盘图标再销毁窗口，最后显式退出进程。
  ///
  /// 仅 `windowManager.destroy()` 在部分平台不结束进程且托盘图标残留
  /// （进程变成无窗口的「僵尸」），故补 [trayManager.destroy] 与 [exit]。
  Future<void> _quit() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }
}
