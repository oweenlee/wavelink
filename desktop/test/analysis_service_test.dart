import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/services/analysis_service.dart';
import 'package:local_music_player/services/stable_hash.dart';

/// AnalysisService 缓存逻辑的纯 Dart 单测（不依赖 Rust 分析 FFI）：
/// 验证内存 + 磁盘双层缓存语义——磁盘命中返回结果、mtime 变化作废、
/// 内存命中优先于磁盘。FFI 路径在 flutter test 宿主不可用（无 rust 动态库），
/// 走 catch 分支返回 null，恰好覆盖「重算失败不崩溃」路径。
void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = Directory.systemTemp.createTempSync('wavelink_analysis_test');
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

  File writeCache(String audioPath, Map<String, dynamic> data) {
    final dir = Directory('${docsDir.path}/.analysis_cache')
      ..createSync(recursive: true);
    final f = File('${dir.path}/${fnv1a(audioPath)}.json');
    f.writeAsStringSync(jsonEncode(data));
    return f;
  }

  group('AnalysisService 磁盘缓存', () {
    test('命中磁盘缓存返回结果（不触发 FFI）', () async {
      final audio = File('${docsDir.path}/a.mp3')..createSync();
      final mtimeMs = (await audio.lastModified()).millisecondsSinceEpoch;
      writeCache(audio.path, {
        'mtimeMs': mtimeMs,
        'bpm': 120.0,
        'key': 'C#m',
        'energy': 0.5,
        'bpmConfidence': 0.9,
        'keyConfidence': 0.8,
      });

      final r = await AnalysisService.instance
          .analyze('tid-disk-hit', audio.path);
      expect(r, isNotNull);
      expect(r!.bpm, 120.0);
      expect(r.key, 'C#m');
      expect(r.bpmConfidence, 0.9);
    });

    test('mtime 变化作废缓存，重算失败返回 null 不崩溃', () async {
      final audio = File('${docsDir.path}/b.mp3')..createSync();
      writeCache(audio.path, {'mtimeMs': 0, 'bpm': 90.0, 'key': 'A'});

      // mtime 不匹配 → 磁盘作废 → 尝试 FFI → 宿主无 rust 库 → 捕获返回 null
      final r = await AnalysisService.instance
          .analyze('tid-disk-stale', audio.path);
      expect(r, isNull);
    });

    test('内存命中优先于磁盘', () async {
      final audio = File('${docsDir.path}/c.mp3')..createSync();
      final mtimeMs = (await audio.lastModified()).millisecondsSinceEpoch;
      writeCache(audio.path, {'mtimeMs': mtimeMs, 'bpm': 111.0, 'key': 'F'});

      final r1 = await AnalysisService.instance
          .analyze('tid-mem-1', audio.path);
      expect(r1!.bpm, 111.0);

      // 磁盘被改写为无效 mtime，但内存已缓存 → 仍返回原值
      writeCache(audio.path, {'mtimeMs': 0, 'bpm': 99.0, 'key': 'G'});
      final r2 = await AnalysisService.instance
          .analyze('tid-mem-1', audio.path);
      expect(r2!.bpm, 111.0);
    });
  });
}
