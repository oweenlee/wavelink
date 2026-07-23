/// 播放杂音排查测试
/// 检测引擎播放连续性和 underrun

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/services/rust_service.dart' as rs;
import '../lib/src/rust/api/audio_output.dart' as audio_out;

void main() {
  setUpAll(() async {
    await rs.initRust();
    await rs.initEngine();
  });

  /// 找 test-media 目录（从项目根目录）
  String? findTestMedia() {
    final candidates = [
      '../test-media',
      '../../test-media',
      '../../../test-media',
    ];
    for (final c in candidates) {
      final d = Directory(c);
      if (d.existsSync()) return d.path;
    }
    return null;
  }

  test('engine plays without underrun', () async {
    final mediaDir = findTestMedia();
    assert(mediaDir != null, 'test-media/ not found');

    // 找一个测试文件
    final files = Directory(mediaDir!).listSync().whereType<File>();
    File? testFile;
    for (final f in files) {
      if (f.path.endsWith('.m4a') || f.path.endsWith('.mp3') || f.path.endsWith('.flac')) {
        testFile = f;
        break;
      }
    }
    assert(testFile != null, 'No audio file found in test-media');
    print('Testing with: ${testFile!.path}');

    // 启动引擎播放
    await rs.enginePlay(testFile.path);

    // 等待播放推进
    await Future.delayed(const Duration(seconds: 2));

    final pos = await rs.enginePositionSecs();
    final underrunBefore = await audio_out.getUnderrunCount();

    print('After 2s: position=$pos secs, underruns=$underrunBefore');

    // 引擎应正在播放，位置应推进
    expect(pos, greaterThan(0.0),
        reason: '引擎未播放，位置为 0');

    // 持续播放 3 秒
    await Future.delayed(const Duration(seconds: 3));

    final posAfter = await rs.enginePositionSecs();
    final underrunAfter = await audio_out.getUnderrunCount();
    final underrunsDuring = underrunAfter - underrunBefore;

    print('After 5s total: position=$posAfter secs, underruns delta=$underrunsDuring');

    // 位置应持续推进
    expect(posAfter, greaterThan(pos),
        reason: '播放未推进');
    // 期望无新增 underrun
    expect(underrunsDuring, equals(BigInt.zero),
        reason: '检测到 underrun，可能有杂音');

    await rs.engineStop();
  });

  test('seek does not cause underrun', () async {
    final mediaDir = findTestMedia();
    assert(mediaDir != null, 'test-media/ not found');

    final files = Directory(mediaDir!).listSync().whereType<File>();
    File? testFile;
    for (final f in files) {
      if (f.path.endsWith('.m4a') || f.path.endsWith('.mp3')) {
        testFile = f;
        break;
      }
    }
    assert(testFile != null, 'No audio file found');

    await rs.enginePlay(testFile!.path);
    await Future.delayed(const Duration(seconds: 1));

    // 连续 seek 5 次
    for (var i = 0; i < 5; i++) {
      final underrunBefore = await audio_out.getUnderrunCount();

      await rs.engineSeek(10.0 + i * 5.0);
      await Future.delayed(const Duration(milliseconds: 500));

      final underrunAfter = await audio_out.getUnderrunCount();
      final delta = underrunAfter - underrunBefore;

      print('Seek #$i: underrun delta=$delta');
      expect(delta, equals(BigInt.zero),
          reason: 'Seek #$i 后出现 underrun');
    }

    await rs.engineStop();
  });
}
