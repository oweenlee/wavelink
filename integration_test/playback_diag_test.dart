/// 播放诊断集成测试 — 在真机上跑，检测引擎 underrun
/// flutter test integration_test/playback_diag_test.dart

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/rust_service.dart' as rs;
import 'package:wavelink_mobile/src/rust/api/audio_output.dart' as audio_out;

void main() {
  testWidgets('诊断：播放和 seek 时的引擎 underrun', (tester) async {
    // 初始化 Rust
    await rs.initRust();
    expect(rs.rustAvailable, isTrue, reason: 'Rust 未加载');

    // 找 test-media 目录
    final mediaDir = _findTestMedia();
    expect(mediaDir, isNotNull, reason: 'test-media/ 未找到');

    // 选一个测试文件
    final testFile = _pickFile(mediaDir!);
    expect(testFile, isNotNull, reason: 'test-media 中没有音频文件');
    print('══════ 测试文件: $testFile ══════');

    await rs.initEngine();

    // ── 1. 启动引擎，检测初始播放 ──
    print('\n--- 阶段1: 初始播放 ---');
    await rs.enginePlay(testFile!);

    // 监控引擎状态
    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final pos = await rs.enginePositionSecs();
      final underrun = await audio_out.getUnderrunCount();
      print('  t=${(i+1)*100}ms position=$pos underrun=$underrun');
    }

    // ── 2. 持续播放 3 秒 ──
    print('\n--- 阶段2: 持续播放 ---');
    final underrunBefore = await audio_out.getUnderrunCount();
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final pos = await rs.enginePositionSecs();
      // 每 1 秒报告一次
      if (i % 10 == 9) {
        print('  t=${i+1}00ms position=$pos');
      }
    }
    final underrunAfter = await audio_out.getUnderrunCount();
    final underrunDelta = (underrunAfter - underrunBefore).toInt();
    print('  持续播放 underrun 增量: $underrunDelta');

    if (underrunDelta > 0) {
      print('  ⚠️ 检测到 $underrunDelta 次 underrun，可能有杂音');
    } else {
      print('  ✅ 无 underrun');
    }

    // ── 3. 快速 seek ──
    print('\n--- 阶段3: 快速 seek ---');
    for (var i = 0; i < 10; i++) {
      final uBefore = await audio_out.getUnderrunCount();
      await rs.engineSeek(5.0 + i * 3.0);
      await Future.delayed(const Duration(milliseconds: 200));
      final uAfter = await audio_out.getUnderrunCount();
      final pos = await rs.enginePositionSecs();
      print('  seek #$i: underrun delta=${(uAfter-uBefore).toInt()} position=$pos');
    }

    await rs.engineStop();

    // ── 4. 反复切歌 ──
    print('\n--- 阶段4: 反复切歌 ---');
    final altFile = _pickFile(mediaDir, exclude: testFile);
    if (altFile != null) {
      for (var i = 0; i < 6; i++) {
        final file = (i % 2 == 0) ? testFile : altFile;
        final uBefore = await audio_out.getUnderrunCount();
        await rs.enginePlay(file);
        await Future.delayed(const Duration(milliseconds: 300));
        await rs.engineStop();
        final uAfter = await audio_out.getUnderrunCount();
        final pos = await rs.enginePositionSecs();
        print('  切歌 #$i: underrun delta=${(uAfter-uBefore).toInt()} position=$pos');
      }
    }

    print('\n══════ 诊断完成 ══════');
  });
}

String? _findTestMedia() {
  for (final path in ['test-media', '../test-media', '../../test-media', '../../../test-media']) {
    if (Directory(path).existsSync()) return Directory(path).path;
  }
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    dir = dir.parent;
    final candidate = '${dir.path}/test-media';
    if (Directory(candidate).existsSync()) return candidate;
  }
  return null;
}

String? _pickFile(String dir, {String? exclude}) {
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final ext = f.path.split('.').last.toLowerCase();
    if ((ext == 'm4a' || ext == 'mp3' || ext == 'flac') && f.path != exclude) {
      return f.path;
    }
  }
  return null;
}
