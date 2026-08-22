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

  group('CoverCache 目录被外部删除后仍可写入（clearAllData 回归）', () {
    test('删除 .covers 目录后 writeCover 能自动重建并成功落盘', () async {
      // 回归：设置页「清空所有数据」会删除 .covers 目录，但单例缓存了
      // 旧目录指针，此后 writeCover 写进不存在的父目录抛异常被静默吞掉
      // → 重新添加音乐后封面永远写不进去（封面图不展示）。
      final file = File('${docsDir.path}/song_readd.mp3')..createSync();
      final t = Track(id: 'r1', title: 'R1', artist: 'R1', filePath: file.path);

      final first = await CoverCache.instance.writeCover(
          t, Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
      expect(first, isNotNull, reason: '首次写入应成功');

      // 模拟 clearAllData 删除缓存目录
      final covers = Directory('${docsDir.path}/.covers');
      expect(await covers.exists(), isTrue);
      await covers.delete(recursive: true);

      // 目录已删除：缓存指针失效，writeCover 必须能重建目录并重新写入
      final second = await CoverCache.instance.writeCover(
          t, Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
      expect(second, isNotNull, reason: '目录被删后再次写入应自动重建');
      expect(File(second!).existsSync(), isTrue);
      expect(second, first, reason: '同 filePath 仍映射到同一缓存路径');
    });
  });
}
