/// 稳定哈希工具：供持久化 key（Track.id / 缓存文件名）使用。
///
/// 为什么不用 `String.hashCode`：Dart 官方不保证 hashCode 跨进程/运行稳定，
/// 且是 32-bit 有碰撞风险。用作 SQLite 主键、缓存文件名等跨重启身份时，
/// 会导致曲目 id 变化（收藏/续播失效）、缓存重复下载。
/// 统一改用 FNV-1a 64-bit（确定性、跨运行稳定），与 mobile 端一致。
String fnv1a(String s) {
  const prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final b in s.codeUnits) {
    hash ^= b;
    hash *= prime;
    // 保持 64-bit 无符号等价（Dart int 为 64-bit 有符号，掩码避免溢出语义差异）
    hash &= 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}