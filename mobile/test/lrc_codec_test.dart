import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/lrc_codec.dart';

void main() {
  test('UTF-8 歌词原样解码', () {
    final bytes = utf8.encode('[00:01.00]测试歌词');
    check(decodeLrcBytes(bytes)).equals('[00:01.00]测试歌词');
  });

  test('GBK 歌词回退解码', () {
    // GBK 编码的 "[00:01.00]测试歌词"（测B2E2 试CAD4 歌B8E8 词B4CA）
    final gbkBytes = [
      0x5b, 0x30, 0x30, 0x3a, 0x30, 0x31, 0x2e, 0x30, 0x30, 0x5d, // [00:01.00]
      0xb2, 0xe2, // 测
      0xca, 0xd4, // 试
      0xb8, 0xe8, // 歌
      0xb4, 0xca, // 词
    ];
    check(decodeLrcBytes(gbkBytes)).equals('[00:01.00]测试歌词');
  });
}
