/// 播放杂音排查测试
/// 检测 ringbuf underrun 和解码连续性

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/services/rust_service.dart' as rs;
import '../lib/src/rust/api/audio_output.dart' as audio_out;

void main() {
  setUpAll(() async {
    await rs.initRust();
    await rs.initRingbuf();
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

  test('decoder pushes data to ringbuf without underrun', () async {
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

    // 启动解码器
    await rs.startDecoder(testFile.path);
    
    // 等待缓冲
    await Future.delayed(const Duration(seconds: 2));
    
    // 检查 ringbuf 状态
    final occupied = await audio_out.debugOccupied();
    final underrunBefore = await audio_out.getUnderrunCount();
    
    print('After 2s buffer: occupied=$occupied, underruns=$underrunBefore');
    
    // ringbuf 应该有数据
    expect(occupied, greaterThan(BigInt.zero), 
        reason: 'ringbuf 为空，解码器未推入数据');
    
    // 模拟 iOS 回调拉取：连续拉 3 秒
    int underrunCount = 0;
    const totalPulls = 120; // 120 * 25ms ≈ 3s
    final leftBuf = Float64List(1024);
    final rightBuf = Float64List(1024);
    
    for (var i = 0; i < totalPulls; i++) {
      // 模拟 fill_buffer_stereo 回调
      // 注意：这里不能直接调 Rust extern "C" 函数，
      // 只能通过 debugOccupied 间接观察
      await Future.delayed(const Duration(milliseconds: 25));
    }
    
    final occupiedAfter = await audio_out.debugOccupied();
    final underrunAfter = await audio_out.getUnderrunCount();
    final underrunsDuring = underrunAfter - underrunBefore;
    
    print('After 3s pull: occupied=$occupiedAfter, underruns delta=$underrunsDuring');
    
    // 期望无新增 underrun
    expect(underrunsDuring, equals(BigInt.zero),
        reason: '检测到 ringbuf underrun，可能有杂音');
    
    await rs.stopDecoder();
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
    
    await rs.startDecoder(testFile!.path);
    await Future.delayed(const Duration(seconds: 1));
    
    // 连续 seek 5 次
    for (var i = 0; i < 5; i++) {
      final underrunBefore = await audio_out.getUnderrunCount();
      
      await rs.stopDecoder();
      await rs.startDecoder(testFile.path, seekSecs: 10.0 + i * 5.0);
      await Future.delayed(const Duration(milliseconds: 500));
      
      final underrunAfter = await audio_out.getUnderrunCount();
      final delta = underrunAfter - underrunBefore;
      
      print('Seek #$i: underrun delta=$delta');
      expect(delta, equals(BigInt.zero),
          reason: 'Seek #$i 后出现 underrun');
    }
    
    await rs.stopDecoder();
  });
}
