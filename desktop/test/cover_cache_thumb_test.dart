import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:local_music_player/services/cover_cache.dart';

/// 缩略图管线测试：
/// 1. ensureThumb 生成 ≤320px 的 JPEG 缩略图（命名派生 `<原图>.thumb.jpg`）
/// 2. 已存在的缩略图不做重复生成（时间戳校验）
/// 3. 损坏图片静默跳过，不留下损坏的 .thumb（.part 已清理/未承诺生成）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {});

  Future<File> writeFixture(Directory dir, int w, int h) async {
    final imgObj = img.Image(width: w, height: h);
    img.fill(imgObj, color: img.ColorRgb8(120, 140, 200));
    final png = img.encodePng(imgObj);
    final file = File('${dir.path}/test_cover.jpg');
    await file.writeAsBytes(png);
    return file;
  }

  test('ensureThumb 生成合法缩略图且尺寸受限', () async {
    final dir = await Directory.systemTemp.createTemp('wavelink_thumb');
    try {
      final full = await writeFixture(dir, 640, 480);
      await CoverCache.instance.ensureThumb(full);

      final thumbPath = CoverCache.thumbPathFor(full.path);
      final thumb = File(thumbPath);
      expect(await thumb.exists(), isTrue, reason: '缩略图应已生成');
      expect(await thumb.length(), lessThan(200 * 1024),
          reason: '320px JPEG 应远小于 200KB');

      final decoded = img.decodeJpg(await thumb.readAsBytes());
      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(CoverCache.thumbSize));
      expect(decoded.height, lessThanOrEqualTo(CoverCache.thumbSize));
      // 宽高比保持（640x480 → 320x240）
      expect(decoded.width / decoded.height, closeTo(4 / 3, 0.02));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('已存在的缩略图不重复生成', () async {
    final dir = await Directory.systemTemp.createTemp('wavelink_thumb2');
    try {
      final full = await writeFixture(dir, 640, 480);
      await CoverCache.instance.ensureThumb(full);
      final thumb = File(CoverCache.thumbPathFor(full.path));
      final mtime = await thumb.lastModified();

      // 再跑一次：不应重写文件
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await CoverCache.instance.ensureThumb(full);
      expect(await thumb.lastModified(), mtime, reason: '缩略图不应被重复生成');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('损坏图片静默跳过不抛异常', () async {
    final dir = await Directory.systemTemp.createTemp('wavelink_thumb3');
    try {
      final full = File('${dir.path}/broken.jpg');
      await full.writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));
      // 应静默返回，无异常，无缩略图
      await CoverCache.instance.ensureThumb(full);
      expect(await File(CoverCache.thumbPathFor(full.path)).exists(), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}