import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/cover_cache.dart';

/// CoverCache 的纯 Dart 单测（不依赖 Rust 引擎 / 真实 FFI）：
/// 只验证「缓存路径如何由 filePath 推导」这一可观测行为，间接覆盖
/// FNV-1a 哈希的确定性（同输入 → 同输出，是跨运行命中缓存的前提）。
///
/// 注意：CoverCache 内部用 path_provider 取文档目录，而 flutter test 宿主
/// 不响应其 method channel（会挂死），故在此 mock 到单一临时目录。
void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = Directory.systemTemp.createTempSync('wavelink_cover_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
  });

  group('CoverCache 缓存路径推导', () {
    test('对本地文件返回稳定且以 .jpg 结尾、落在 .covers 下的路径', () async {
      final file = File('${docsDir.path}/song_a.mp3')..createSync();
      final t = Track(id: 'a', title: 'A', artist: 'A', filePath: file.path);

      final p1 = await CoverCache.instance.cacheFilePathFor(t);
      final p2 = await CoverCache.instance.cacheFilePathFor(t);

      expect(p1, isNotNull);
      expect(p1, endsWith('.jpg'));
      expect(p1, contains('.covers')); // 落在 <文档>/.covers 下
      expect(p1, p2); // 确定性：同输入同输出（FNV-1a 稳定）
    });

    test('不同 filePath 映射到不同缓存路径', () async {
      final f1 = File('${docsDir.path}/song_b1.mp3')..createSync();
      final f2 = File('${docsDir.path}/song_b2.mp3')..createSync();
      final t1 = Track(id: 'b1', title: 'B1', artist: 'B1', filePath: f1.path);
      final t2 = Track(id: 'b2', title: 'B2', artist: 'B2', filePath: f2.path);

      final p1 = await CoverCache.instance.cacheFilePathFor(t1);
      final p2 = await CoverCache.instance.cacheFilePathFor(t2);
      expect(p1, isNot(p2));
    });
  });

  group('CoverCache.cachedPathFor', () {
    test('文件不存在或 filePath 为 null 时返回 null（未提取则不命中）', () async {
      final missing = Track(
        id: 'c1',
        title: 'C1',
        artist: 'C1',
        filePath:
            '${docsDir.path}/no_such_${DateTime.now().microsecondsSinceEpoch}.mp3',
      );
      expect(await CoverCache.instance.cachedPathFor(missing), isNull);

      final noPath = Track(id: 'c2', title: 'C2', artist: 'C2');
      expect(await CoverCache.instance.cachedPathFor(noPath), isNull);
    });
  });
}
