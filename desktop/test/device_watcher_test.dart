import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/services/audio_settings_provider.dart';
import 'package:local_music_player/services/device_watcher.dart';
import 'package:local_music_player/services/engine.dart';
import 'package:local_music_player/services/player_notifier.dart';
import 'package:local_music_player/services/player_providers.dart';

/// 可配置设备列表的假引擎。
class FakeEngine extends Engine {
  List<String> devices = const ['内置扬声器', 'HDMI'];
  String? setOutputDeviceName;
  int enumerateCalls = 0;

  @override
  Future<List<String>> enumerateDevices() async {
    enumerateCalls++;
    return devices;
  }

  @override
  Future<void> setOutputDevice(String? name) async =>
      setOutputDeviceName = name;

  @override
  Future<int> outputSampleRate() async => 48000;
}

class FakePlayerNotifier extends PlayerNotifier {
  final Engine? _testEngine;
  FakePlayerNotifier(this._testEngine);

  @override
  PlayerState build() {
    ref.onDispose(() => dispose());
    return const PlayerState(engineReady: true);
  }

  @override
  Engine? get engine => _testEngine;
}

void main() {
  late ProviderContainer container;
  late FakeEngine fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'outputDevice': 'HDMI'});
    fake = FakeEngine();
    container = ProviderContainer(
      overrides: [playerProvider.overrideWith(() => FakePlayerNotifier(fake))],
    );
    // audioSettingsProvider 在 _restore 中异步读 prefs + 枚举设备，
    // 先触发构建等 restore 完成（restore 只读不写，无外部依赖）。
    container.read(audioSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() => container.dispose());

  test('设备列表变化时刷新设置页设备下拉', () async {
    final watcher = DeviceWatcher(container);
    // 首轮：建立基线（_lastDevices 初始为空 → 视为变化，顺带刷新一次）
    await watcher.tickForTest();
    expect(container.read(audioSettingsProvider).devices,
        containsAll(['内置扬声器', 'HDMI']));
    // 设备插入（蓝牙）→ 下一轮检测到变化 → refreshDevices
    fake.devices = const ['内置扬声器', 'HDMI', '蓝牙耳机'];
    await watcher.tickForTest();
    expect(container.read(audioSettingsProvider).devices,
        containsAll(['内置扬声器', 'HDMI', '蓝牙耳机']));
    // selectedDevice（HDMI）仍在列表中 → 不回退默认，不打扰用户
    expect(fake.setOutputDeviceName, isNull);
  });

  test('选中设备被拔出时自动回退系统默认并提示', () async {
    final watcher = DeviceWatcher(container);
    await watcher.tickForTest(); // 基线
    expect(container.read(audioSettingsProvider).selectedDevice, 'HDMI');

    final notices = <String>[];
    final sub = container
        .read(playerProvider.notifier)
        .errorStream
        .listen(notices.add);

    // HDMI 被拔出
    fake.devices = const ['内置扬声器'];
    await watcher.tickForTest();
    expect(fake.setOutputDeviceName, isNull); // 本轮先刷新再比对
    await watcher.tickForTest(); // 下一轮选中设备已消失 → 回退
    expect(fake.setOutputDeviceName, isNull);
    // selectDevice(null) 持久化落地：AudioSettingsState.selectedDevice 清空
    expect(container.read(audioSettingsProvider).selectedDevice, isNull);
    expect(notices, isNotEmpty); // SnackBar 提示已发出
    await sub.cancel();
  });
}