import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/domain/models/nas_profile.dart';

void main() {
  NasProfile profile({
    String host = '192.168.1.5',
    int port = 445,
    String share = '/Music',
    String username = 'user',
    String password = 'pass',
    String? type = 'smb',
    DateTime? savedAt,
  }) =>
      NasProfile(
        host: host,
        port: port,
        share: share,
        username: username,
        password: password,
        type: type,
        savedAt: savedAt ?? DateTime(2026, 1, 1),
      );

  group('NasProfile 序列化', () {
    test('toJson/fromJson 往返保留全部字段', () {
      final p = profile(
        host: 'nas.local',
        port: 139,
        share: '/Music/FLAC',
        username: 'alice',
        password: 'secret',
        type: null,
        savedAt: DateTime(2026, 6, 15, 10, 30),
      );
      final restored = NasProfile.fromJson(p.toJson());
      check(restored.host).equals('nas.local');
      check(restored.port).equals(139);
      check(restored.share).equals('/Music/FLAC');
      check(restored.username).equals('alice');
      check(restored.password).equals('secret');
      check(restored.type).isNull();
      check(restored.savedAt).equals(DateTime(2026, 6, 15, 10, 30));
    });

    test('fromJson 缺失字段用默认值', () {
      final p = NasProfile.fromJson({});
      check(p.host).equals('');
      check(p.port).equals(445);
      check(p.share).equals('');
      check(p.username).equals('');
      check(p.password).equals('');
      check(p.type).isNull();
      check(p.savedAt.millisecondsSinceEpoch).equals(0);
    });

    test('savedAt 无法解析时兜底为 epoch', () {
      final p = NasProfile.fromJson({'savedAt': 'not-a-date'});
      check(p.savedAt.millisecondsSinceEpoch).equals(0);
    });
  });

  group('NasProfile 指纹 id', () {
    test('host 大小写不敏感、share 忽略首尾空格', () {
      final a = profile(host: 'NAS.LOCAL', share: ' /Music ');
      final b = profile(host: 'nas.local', share: '/Music');
      check(a.id).equals(b.id);
      check(a.sameTarget(b)).isTrue();
    });

    test('port 不同则视为不同目标', () {
      final a = profile(port: 445);
      final b = profile(port: 139);
      check(a.id).not((x) => x.equals(b.id));
      check(a.sameTarget(b)).isFalse();
    });

    test('share 不同则视为不同目标', () {
      final a = profile(share: '/Music');
      final b = profile(share: '/Movies');
      check(a.sameTarget(b)).isFalse();
    });

    test('凭据不影响指纹', () {
      final a = profile(username: 'u1', password: 'p1');
      final b = profile(username: 'u2', password: 'p2');
      check(a.id).equals(b.id);
      check(a.sameTarget(b)).isTrue();
    });
  });

  group('NasProfile displayName', () {
    test('有 share 时取共享路径第一段', () {
      final p = profile(share: '/Music/FLAC');
      check(p.displayName).equals('192.168.1.5 · Music');
    });

    test('无 share 时只显示 host（去首尾空格）', () {
      final p = profile(host: ' nas.local ', share: '');
      check(p.displayName).equals('nas.local');
    });
  });
}
