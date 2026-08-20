import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/services/engine.dart';
import 'package:local_music_player/services/library.dart';
import 'package:local_music_player/src/rust/api/cue.dart' as frb_cue;
import 'package:local_music_player/src/rust/api/metadata.dart' as frb_metadata;

/// 桥接层集成测试：加载真实 Rust 动态库，验证本轮补齐的 DSP / 采样率桥函数
/// 经 Dart→FRB→Rust 全链路可调用且不 panic。仅验证链路通畅（不依赖音源/音频设备）：
/// 未 init 时 getter 返回安全默认值，setter 为空操作。
///
/// 需要先用 `cargo build -p wavelink_desktop` 产出 dylib；缺失则跳过（不视为失败）。
void main() {
  test('bridge: new DSP / sample-rate functions callable via FFI', () async {
    final engine = await _sharedEngine();
    if (engine == null) {
      markTestSkipped(
          'wavelink_desktop dylib 未构建，先运行 `cargo build -p wavelink_desktop`');
      return;
    }

    // 未 init 时安全默认值
    expect(await engine.outputSampleRate(), 0);
    expect(await engine.underrunCount(), 0);

    // 本轮补齐的全部桥函数：应可调用且不抛
    await engine.setStereoWidener(true, 0.5);
    await engine.setCrossfeed(true);
    await engine.setLimiter(true);
    await engine.setDither(true);
    await engine.setNoiseShaping(true);
    await engine.setReplaygainGain(-3.0);
    await engine.setSpeed(1.25);
    await engine.applyPreset('flat');
    await engine.setAutoEq(null);
    await engine.setOutputSampleRate(48000);
    await engine.clearIr();
    await engine.loadIr('/tmp/ir.wav');
    await engine.setPeqBand(0, 1000.0, -3.0, 1.0);

    // 设备枚举不抛、返回列表
    final devs = await engine.enumerateDevices();
    expect(devs, isA<List<String>>());

    // CUE 队列清理桥函数：未 init 时安全 no-op
    await engine.removeQueueEntry(1);
  });

  test('bridge: readMetadata / parseCueBytes 全链路（真实 dylib）', () async {
    final engine = await _sharedEngine();
    if (engine == null) {
      markTestSkipped(
          'wavelink_desktop dylib 未构建，先运行 `cargo build -p wavelink_desktop`');
      return;
    }

    final tmp = Directory.systemTemp.createTempSync('wavelink_meta_test');
    try {
      // 1) 元数据：无标签 WAV → 标题 null、时长可探（2s）
      final wav = File('${tmp.path}/ArtistX - SongY.wav');
      await wav.writeAsBytes(_makeWav());
      final meta = await frb_metadata.readMetadata(path: wav.path);
      expect(meta.title, isNull); // WAV 无标签，由扫描层降级文件名解析
      expect(meta.durationSecs, closeTo(2.0, 0.2));
      expect(meta.hasCover, isFalse);

      // 2) CUE（UTF-8）：两轨展平 + FILE 相对路径按基准目录转绝对
      final cueText = 'TITLE "整轨专辑"\n'
          'PERFORMER "某艺人"\n'
          'FILE "${wav.path.split(Platform.pathSeparator).last}" WAVE\n'
          '  TRACK 01 AUDIO\n'
          '    TITLE "第一首"\n'
          '    INDEX 01 00:00:00\n'
          '  TRACK 02 AUDIO\n'
          '    TITLE "第二首"\n'
          '    INDEX 01 00:01:00\n';
      final sheet = await frb_cue.parseCueBytes(
        data: Uint8List.fromList(utf8.encode(cueText)),
        baseDir: tmp.path,
      );
      expect(sheet.title, '整轨专辑');
      expect(sheet.files.single.tracks.length, 2);
      expect(sheet.files.single.path, wav.path); // 相对路径已解析为绝对
      expect(sheet.files.single.tracks[1].startSecs, closeTo(1.0, 1e-6));

      // 3) CUE（GBK 编码，非法 UTF-8 → GBK 回退分支）
      final gbk = <int>[
        ..._ascii('TITLE "'), 0xD7, 0xA8, 0xBC, 0xAD, ..._ascii('"\n'),
        ..._ascii('PERFORMER "'), 0xB8, 0xE8, 0xCA, 0xD6, ..._ascii('"\n'),
        ..._ascii('FILE "a.wav" WAVE\n'),
        ..._ascii('  TRACK 01 AUDIO\n'),
        ..._ascii('    INDEX 01 00:00:00\n'),
      ];
      final gbkSheet = await frb_cue.parseCueBytes(
        data: Uint8List.fromList(gbk),
        baseDir: tmp.path,
      );
      expect(gbkSheet.title, '专辑'); // GBK 正确解码
      expect(gbkSheet.performer, '歌手');

      // 4) scanFolder 全链路：cue 拆轨 + 镜像排除 + 普通曲目共存
      final cueFile = File('${tmp.path}/album.cue');
      await cueFile.writeAsString(cueText);
      final other = File('${tmp.path}/Someone - Else.wav');
      await other.writeAsBytes(_makeWav());
      final tracks = await scanFolder(tmp.path);
      // 2 首 cue 虚拟轨 + 1 首普通曲；镜像 album 内容 wav 不重复入库
      expect(tracks.length, 3);
      expect(tracks.where((t) => t.isCueTrack).length, 2);
      expect(tracks.any((t) => t.filePath == wav.path && !t.isCueTrack),
          isFalse);
      final cueTracks = tracks.where((t) => t.isCueTrack).toList()
        ..sort((a, b) => a.cueTrackIndex!.compareTo(b.cueTrackIndex!));
      expect(cueTracks[0].title, '第一首');
      expect(cueTracks[0].artist, '某艺人'); // 轨未声明艺人 → 回退整碟
      expect(cueTracks[0].album, '整轨专辑');
      expect(cueTracks[0].durationHint, isNotNull); // 下一轨起点即终点
      expect(cueTracks[1].durationHint, isNull); // 末轨由引擎时长事件回填
      expect(cueTracks[0].cueTrackCount, 2);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

List<int> _ascii(String s) => s.codeUnits;

/// 全文件共享的引擎加载（RustLib.init 只调一次，避免重复初始化）。
Future<Engine?> _sharedEngine() {
  return _engineFuture ??= Engine.load(dylibPath: _resolveDylib());
}

Future<Engine?>? _engineFuture;

/// 生成最小可解析 WAV（16bit PCM mono 8kHz，2 秒静音）供 symphonia 探测。
Uint8List _makeWav({int sampleRate = 8000, int frames = 16000}) {
  final dataSize = frames * 2;
  final b = BytesBuilder();
  void u32(int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  b.add('RIFF'.codeUnits);
  u32(36 + dataSize);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits per sample
  b.add('data'.codeUnits);
  u32(dataSize);
  b.add(List.filled(dataSize, 0));
  return b.toBytes();
}

String? _resolveDylib() {
  final candidates = [
    '../target/debug/libwavelink_desktop.dylib',
    '../target/release/libwavelink_desktop.dylib',
    'target/debug/libwavelink_desktop.dylib',
    'target/release/libwavelink_desktop.dylib',
    'rust/target/debug/libwavelink_desktop.dylib',
    '/Users/qin/Desktop/wavelink/target/debug/libwavelink_desktop.dylib',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
