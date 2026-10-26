import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// 从 integration_test 的响应数据里取出 takeScreenshot 的 bytes，写到本地。
/// 运行： flutter drive --driver=test_driver/screenshot_driver.dart \
///        --target=integration_test/capture_screens_test.dart --no-pub -d <udid>
Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (Map<String, dynamic>? data) async {
    final list = (data?['screenshots'] as List?) ?? const [];
    final dir = Directory('/Users/qin/Desktop/wavelink/mobile/build/asc-captures');
    await dir.create(recursive: true);
    var i = 0;
    for (final e in list) {
      final m = e as Map;
      final name = (m['name'] as String?) ?? 'shot_${i++}';
      final bytes = (m['bytes'] as List).cast<int>();
      final file = File('${dir.path}/$name.png');
      await file.writeAsBytes(bytes, flush: true);
      // ignore: avoid_print
      print('WROTE ${file.path} (${bytes.length} bytes)');
    }
  },
);
