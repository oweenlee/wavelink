import 'dart:ui';
import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/domain/models/song.dart';
import 'package:wavelink_mobile/ui/features/library/view_models/cover_service.dart';

/// 通过 probe provider 取出 Ref，供 CoverService 构造使用。
final _refProbe = Provider<Ref>((ref) => ref);

Song _song({
  String id = 's',
  String? path,
  String? smbPath,
  String? davPath,
  String? streamUrl,
  bool strm = false,
  String? targetKind,
  String? coverUrl,
  String album = 'Album',
  bool durationEstimated = false,
}) =>
    Song(
      id: id,
      title: id,
      artist: 'Artist',
      album: album,
      duration: const Duration(seconds: 100),
      dominantColor: const Color(0xFF000000),
      path: path,
      smbPath: smbPath,
      davPath: davPath,
      streamUrl: streamUrl,
      strmPath: strm ? '/s.strm' : null,
      targetKind: targetKind,
      coverUrl: coverUrl,
      durationEstimated: durationEstimated,
    );

void main() {
  CoverService buildService() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return CoverService(container.read(_refProbe));
  }

  group('CoverService.pendingNasCovers 筛选', () {
    test('SMB / WebDAV 远端索引歌（无封面）被选中', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'smb', smbPath: 'Music/a.flac'),
        _song(id: 'dav', davPath: 'Music/b.flac'),
      ]);
      check(pending.map((s) => s.id)).deepEquals(['smb', 'dav']);
    });

    test('本地文件歌（path 非空）被剔除', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'smb', smbPath: 'Music/a.flac', path: '/tmp/a.flac'),
      ]);
      check(pending).isEmpty();
    });

    test('封面已就绪且元数据非占位时被剔除', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'ready', smbPath: 'Music/a.flac', coverUrl: '/tmp/c.jpg'),
      ]);
      check(pending).isEmpty();
    });

    test('封面就绪但元数据仍是占位值（NAS Music）时保留回填', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'need', smbPath: 'Music/a.flac', coverUrl: '/tmp/c.jpg', album: 'NAS Music'),
      ]);
      check(pending.map((s) => s.id)).deepEquals(['need']);
    });

    test('封面就绪但时长仍为估算值时保留', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'est', smbPath: 'Music/a.flac', coverUrl: '/tmp/c.jpg', durationEstimated: true),
      ]);
      check(pending.map((s) => s.id)).deepEquals(['est']);
    });

    test('STRM 歌按解析目标分流（smb 选中、http 剔除）', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'strm-smb', strm: true, targetKind: 'smb'),
        _song(id: 'strm-dav', strm: true, targetKind: 'dav'),
        _song(id: 'strm-http', strm: true, targetKind: 'http'),
      ]);
      check(pending.map((s) => s.id)).deepEquals(['strm-smb', 'strm-dav']);
    });

    test('流式歌（streamUrl）被剔除', () {
      final pending = CoverService.pendingNasCovers([
        _song(id: 'stream', streamUrl: 'https://x/audio.mp3'),
      ]);
      check(pending).isEmpty();
    });
  });

  group('CoverService.pendingLocalCovers 筛选', () {
    test('仅选缺封面且有本地文件的歌', () {
      final pending = CoverService.pendingLocalCovers([
        _song(id: 'a', path: '/tmp/a.flac'),
        _song(id: 'b', path: '/tmp/b.flac', coverUrl: '/tmp/c.jpg'),
        _song(id: 'c'),
      ]);
      check(pending.map((s) => s.id)).deepEquals(['a']);
    });
  });

  group('CoverService.resetForConfigChange', () {
    test('可安全调用，且重置后提取流程仍能正常触发', () async {
      final service = buildService();
      service.resetForConfigChange();
      // 队列清空后再触发提取：无待提取歌时循环应立即退出（不触发网络）
      await service
          .extractNasCovers([_song(id: 'ready', smbPath: 'Music/a.flac', coverUrl: '/tmp/c.jpg')]);
      service.resetForConfigChange();
    });
  });
}