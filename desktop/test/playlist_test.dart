import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/models/playlist.dart';

void main() {
  group('Playlist 序列化往返', () {
    test('完整字段往返一致', () {
      const p = Playlist(
        id: 'pl-1',
        name: '夜间歌单',
        trackIds: ['t1', 't2', 't3'],
      );
      final restored = Playlist.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, p.id);
      expect(restored.name, p.name);
      expect(restored.trackIds, p.trackIds);
    });

    test('空 trackIds 往返一致', () {
      const p = Playlist(id: 'pl-2', name: 'empty');
      final restored = Playlist.fromJson(p.toJson());
      expect(restored.trackIds, isEmpty);
    });

    test('fromJson 对缺失 trackIds 容错', () {
      final p = Playlist.fromJson({'id': 'pl-3', 'name': 'legacy'});
      expect(p.trackIds, isEmpty);
    });
  });
}
