import 'dart:convert';

/// 稳定字符串哈希（FNV-1a 64-bit）。
///
/// Dart 的 `String.hashCode` 在同一进程内可用，但不保证跨进程/版本稳定，
/// 不能用于 Song id 或磁盘缓存文件名。这里统一使用 FNV-1a 64-bit，
/// 并输出定长 16 位十六进制字符串，碰撞概率远低于 32-bit hash。
/// 与原有 import_service 的 64-bit FNV-1a 保持 UTF-8 字节语义一致。
String stableHash(String input) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
