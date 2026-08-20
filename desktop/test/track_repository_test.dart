import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/track_repository.dart';

/// TrackRepository 的纯 Dart 集成测试（不依赖 Rust 引擎）：
/// 在 macOS 宿主上走 sqflite_common_ffi 真实落盘，验证「存取往返 + 增量
/// 合并 + 删除清理 + 清空」四条关键路径，覆盖纯 JSON 方案无法保证的原子性。
///
/// 注意：path_provider 的 method channel 在 flutter test 宿主下不响应
/// （会挂死），故 mock `getApplicationSupportDirectory` 到单一临时目录。
void main() {
  late Directory supportDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    supportDir =
        Directory.systemTemp.createTempSync('wavelink_repo_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return supportDir.path;
        }
        return null;
      },
    );
  });

  setUp(() async {
    await TrackRepository.init();
    await TrackRepository.clear();
  });

  tearDown(() async {
    await TrackRepository.clear();
  });

  group('本地文件夹：整段替换 + 删除清理', () {
    test('首次扫描写入，二次扫描（子集）自动清理已删文件', () async {
      final a = Track(
        id: '/m/a.flac',
        title: 'A',
        artist: 'X',
        source: TrackSource.local,
        filePath: '/m/a.flac',
        durationHint: const Duration(seconds: 200),
      );
      final b = Track(
        id: '/m/b.flac',
        title: 'B',
        artist: 'Y',
        source: TrackSource.local,
        filePath: '/m/b.flac',
      );
      await TrackRepository.syncScan([a, b], localPrefix: '/m');

      var all = await TrackRepository.getAll();
      expect(all.length, 2);

      // 重新扫描：文件夹里只剩 a（b 被删）
      await TrackRepository.syncScan([a], localPrefix: '/m');
      all = await TrackRepository.getAll();
      expect(all.length, 1);
      expect(all.first.id, '/m/a.flac');
    });

    test('字段往返：Duration/bool/enum 经毫秒与 0/1 正确还原', () async {
      final t = Track(
        id: '/m/s.strm',
        title: 'S',
        artist: 'Z',
        source: TrackSource.nas,
        remotePath: 'share/s.strm',
        durationHint: const Duration(milliseconds: 123456),
        durationEstimated: true,
        strmPath: 'share/s.strm',
        strmFromWebdav: true,
        targetUri: 'smb://host/x.flac',
        targetKind: 'smb',
      );
      await TrackRepository.syncScan([t], source: TrackSource.nas);

      final all = await TrackRepository.getAll();
      expect(all.length, 1);
      final r = all.first;
      expect(r.source, TrackSource.nas);
      expect(r.durationHint, const Duration(milliseconds: 123456));
      expect(r.durationEstimated, isTrue);
      expect(r.strmFromWebdav, isTrue);
      expect(r.targetUri, 'smb://host/x.flac');
      expect(r.targetKind, 'smb');
    });

    test('字段往返：CUE 分轨与标签元数据字段正确还原', () async {
      final t = Track(
        id: '/m/album.cue#01',
        title: '第一首',
        artist: '某艺人',
        album: '整轨专辑',
        source: TrackSource.local,
        filePath: '/m/album.flac',
        trackNumber: 1,
        lyricsText: '[00:01.00]内嵌歌词',
        cuePath: '/m/album.cue',
        cueTrackIndex: 0,
        cueTrackCount: 9,
      );
      expect(t.isCueTrack, isTrue);
      await TrackRepository.syncScan([t], localPrefix: '/m');

      final r = (await TrackRepository.getAll()).single;
      expect(r.album, '整轨专辑');
      expect(r.trackNumber, 1);
      expect(r.lyricsText, '[00:01.00]内嵌歌词');
      expect(r.isCueTrack, isTrue);
      expect(r.cuePath, '/m/album.cue');
      expect(r.cueTrackIndex, 0);
      expect(r.cueTrackCount, 9);
    });
  });

  group('网络音源：按来源差集清理已移除曲目', () {
    test('服务器删曲后重扫，该来源库存自动收敛', () async {
      final n1 = Track(
        id: 'nas_1',
        title: 'N1',
        artist: 'Z',
        source: TrackSource.nas,
        remotePath: 'music/n1.flac',
      );
      final n2 = Track(
        id: 'nas_2',
        title: 'N2',
        artist: 'Z',
        source: TrackSource.nas,
        remotePath: 'music/n2.flac',
      );
      await TrackRepository.syncScan([n1, n2], source: TrackSource.nas);

      var all = await TrackRepository.getAll();
      expect(all.where((t) => t.source == TrackSource.nas).length, 2);

      // 服务器移除 n2
      await TrackRepository.syncScan([n1], source: TrackSource.nas);
      all = await TrackRepository.getAll();
      expect(all.where((t) => t.source == TrackSource.nas).length, 1);
      expect(all.first.id, 'nas_1');
    });

    test('清空整库后 getAll 返回空', () async {
      final t = Track(
        id: 'sub_1',
        title: 'S',
        artist: 'Z',
        source: TrackSource.subsonic,
        streamUrl: 'http://x/1',
      );
      await TrackRepository.syncScan([t], source: TrackSource.subsonic);
      await TrackRepository.clear();
      expect(await TrackRepository.getAll(), isEmpty);
    });
  });
}
