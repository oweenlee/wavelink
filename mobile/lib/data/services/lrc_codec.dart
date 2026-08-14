import 'dart:convert';

import 'package:charset/charset.dart';

/// 歌词字节解码：先严格 UTF-8（合法 UTF-8 原样通过），失败回退 GBK。
/// 中文歌词库（群晖/Nextcloud 等）大量 `.lrc` 是 GBK/GB2312 编码，
/// 直接 `utf8.decode(allowMalformed: true)` 会输出乱码；而宽松解码
/// 的 UTF-8 又把 GBK 字节"硬解"成乱码。严格模式会拒绝 GBK 的高位
/// 双字节序列（含非法 UTF-8 序列），从而可靠地触发回退。
String decodeLrcBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    try {
      return gbk.decode(bytes);
    } catch (_) {
      // 极端兜底：GBK 也失败时回到宽松 UTF-8，保证不抛异常
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
