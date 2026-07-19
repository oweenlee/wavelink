/// 播放稳定性集成测试 — 在真机上跑
/// flutter test integration_test/playback_test.dart

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/services/rust_service.dart' as rs;
import 'package:wavelink_mobile/src/rust/api/audio_output.dart' as audio_out;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String mediaDir;

  setUpAll(() async {
    await rs.initRust();
    expect(rs.rustAvailable, isTrue, reason: 'Rust 未加载');

    // 找 test-media
    mediaDir = _findTestMedia();
    expect(mediaDir, isNotEmpty, reason: 'test-media/ 未找到');
  });

  /// 测试：单曲稳态播放无 underrun
  test('稳态播放 should have zero underrun', () async {
    await rs.initRingbuf();

    // 选取一个典型的 44.1kHz 文件
    final file = _pickFile(mediaDir, ext: 'm4a');
    expect(file, isNotNull, reason: '没有 m4a 文件');
    print('文件: $file');

    // 播放
    await rs.startDecoder(file!);
    await audio_out.waitForReady(timeoutMs: BigInt.from(5000));

    // 等待缓冲
    await Future.delayed(const Duration(seconds: 2));

    final underrunBefore = await audio_out.getUnderrunCount();
    print('underrun 初始值: $underrunBefore');

    // 持续播放 5 秒
    await Future.delayed(const Duration(seconds: 5));

    final underrunAfter = await audio_out.getUnderrunCount();
    final delta = (underrunAfter - underrunBefore).toInt();
    print('5 秒后 underrun: $underrunAfter, 增量: $delta');

    expect(delta, lessThanOrEqualTo(0),
        reason: '稳态播放不应 underrun，增量为 $delta');
  });

  /// 测试：单个 seek 后无 underrun
  test('单次 seek 后 should have zero underrun', () async {
    await rs.initRingbuf();

    final file = _pickFile(mediaDir, ext: 'm4a');
    expect(file, isNotNull);

    await rs.startDecoder(file!);
    await Future.delayed(const Duration(seconds: 2));

    // seek 到 30 秒处
    await rs.stopDecoder();
    await rs.startDecoder(file!, seekSecs: 30.0);
    await audio_out.waitForReady(timeoutMs: BigInt.from(5000));
    await Future.delayed(const Duration(milliseconds: 500));

    final underrunBefore = await audio_out.getUnderrunCount();

    // 等待 3 秒
    await Future.delayed(const Duration(seconds: 3));

    final underrunAfter = await audio_out.getUnderrunCount();
    final delta = (underrunAfter - underrunBefore).toInt();
    print('seek 后 3s underrun 增量: $delta');

    expect(delta, lessThanOrEqualTo(0),
        reason: 'seek 后不应 underrun');
  });

  /// 测试：连续 5 次 seek（模拟快速滑动）
  test('连续 seek 5 次 should not spike underrun', () async {
    await rs.initRingbuf();

    final file = _pickFile(mediaDir, ext: 'm4a');
    expect(file, isNotNull);

    await rs.startDecoder(file!);
    await Future.delayed(const Duration(seconds: 2));

    final underrunBefore = await audio_out.getUnderrunCount();
    int maxDelta = 0;

    for (var i = 0; i < 5; i++) {
      await rs.stopDecoder();
      await rs.startDecoder(file!, seekSecs: (10.0 + i * 15.0).toDouble());
      await audio_out.waitForReady(timeoutMs: BigInt.from(3000));
      await Future.delayed(const Duration(milliseconds: 200));

      final ur = await audio_out.getUnderrunCount();
      final delta = (ur - underrunBefore).toInt();
      if (delta > maxDelta) maxDelta = delta;
      print('  seek #$i: underrun 增量=$delta');
    }

    print('最大 underrun 增量: $maxDelta');
    expect(maxDelta, lessThanOrEqualTo(1),
        reason: '连续 seek 时 underrun 不应超过 1 次');
  });

  /// 测试：快速切歌（3 首不同的歌）
  test('快速切歌 3 次 should be stable', () async {
    await rs.initRingbuf();

    final files = [_pickFile(mediaDir, ext: 'm4a')!, _pickFile(mediaDir, ext: 'mp3')!, _pickFile(mediaDir, ext: 'flac')!];
    print('测试文件: $files');

    final underrunBefore = await audio_out.getUnderrunCount();

    for (var i = 0; i < 3; i++) {
      await rs.startDecoder(files[i % files.length]);
      await audio_out.waitForReady(timeoutMs: BigInt.from(5000));
      await Future.delayed(const Duration(seconds: 1));
    }

    final underrunAfter = await audio_out.getUnderrunCount();
    final delta = (underrunAfter - underrunBefore).toInt();
    print('切歌后 underrun 增量: $delta');

    expect(delta, lessThanOrEqualTo(1),
        reason: '切歌后 underrun 不应超过 1 次');
  });

  /// 测试：44.1kHz vs 48kHz 文件对比
  test('48kHz 文件播放应无杂音', () async {
    await rs.initRingbuf();

    // 找一个 48kHz 文件（蔡琴的就是 48kHz）
    final files = Directory(mediaDir).listSync().whereType<File>().toList();
    File? file48k;
    for (final f in files) {
      if (f.path.endsWith('.mp3') && f.path.contains('蔡琴')) {
        file48k = f;
        break;
      }
    }
    expect(file48k, isNotNull, reason: '未找到 48kHz 测试文件');
    print('48kHz 文件: ${file48k!.path}');

    await rs.startDecoder(file48k.path);
    await audio_out.waitForReady(timeoutMs: BigInt.from(5000));

    // 缓冲
    await Future.delayed(const Duration(seconds: 2));

    final underrunBefore = await audio_out.getUnderrunCount();
    print('初始 underrun: $underrunBefore');

    // 播放 5 秒
    await Future.delayed(const Duration(seconds: 5));

    final underrunAfter = await audio_out.getUnderrunCount();
    final delta = (underrunAfter - underrunBefore).toInt();
    print('48kHz 5s 后 underrun 增量: $delta');

    expect(delta, lessThanOrEqualTo(0),
        reason: '48kHz 文件播放不应 underrun（硬件采样率适配后）');
  });
}

String _findTestMedia() {
  for (final path in ['test-media', '../test-media', '../../test-media']) {
    if (Directory(path).existsSync()) return Directory(path).path;
  }
  // 从当前目录往上找 5 层
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    dir = dir.parent;
    final candidate = '${dir.path}/test-media';
    if (Directory(candidate).existsSync()) return candidate;
  }
  return '';
}

String? _pickFile(String dir, {String? ext}) {
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final e = f.path.split('.').last.toLowerCase();
    if (ext == null && (e == 'm4a' || e == 'mp3' || e == 'flac')) return f.path;
    if (ext != null && e == ext) return f.path;
  }
  return null;
}
