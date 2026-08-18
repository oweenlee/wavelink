import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_music_player/screens/home.dart';
import 'package:local_music_player/services/network_source_config.dart';

void main() {
  // flutter test 的桌面测试宿主里 shared_preferences 的原生 method channel
  // 不会响应，直接 SharedPreferences.getInstance() 会挂死。测试前先用 mock
  // 初始值，让 getInstance() 立即返回，避免 hang。
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('HomeScreen renders empty-library guidance', (tester) async {
    // 真实 main() 会先初始化 NetworkSourceConfig；侧栏网络音源区依赖它。
    await NetworkSourceConfig.init();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: HomeScreen())),
    );

    expect(find.text('曲库为空'), findsOneWidget);
    // 侧栏入口 + 空库引导按钮，共两处
    expect(find.text('添加音乐文件夹'), findsWidgets);
    expect(find.text('音乐库'), findsWidgets);
  });

  testWidgets('sidebar shows library / favorites / playlist sections',
      (tester) async {
    await NetworkSourceConfig.init();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: HomeScreen())),
    );

    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('新建播放列表'), findsOneWidget);
  });
}
