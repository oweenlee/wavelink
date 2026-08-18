import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../src/rust/api/cover.dart' as frb_cover;

/// 本地封面缓存与提取。
///
/// 对齐 mobile 的「封面为本地缓存文件」策略：从音频文件内嵌封面提取字节，
/// 落盘到 `<文档>/.covers/<稳定hash>.jpg`，再以 `Image.file` 渲染。
/// 缓存文件名用稳定哈希（FNV-1a），保证跨进程重启命中、不重复提取。
class CoverCache {
  CoverCache._();

  /// 单例（与播放器生命周期一致）。
  static final CoverCache instance = CoverCache._();

  Directory? _dir;

  Future<Directory> get _cacheDir async {
    if (_dir != null) return _dir!;
    final appDir = await getApplicationDocumentsDirectory();
    _dir = Directory(p.join(appDir.path, '.covers'));
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  /// 稳定缓存键：filePath 的 FNV-1a 十六进制（跨运行一致）。
  String _keyFor(Track t) =>
      t.filePath != null ? _fnv1a(t.filePath!) : t.id;

  /// 纯路径推导（不检查是否存在）：`<缓存目录>/<键>.jpg`。
  ///
  /// 确定性：相同 `(track, 文档目录)` → 相同输出，是跨进程重启命中缓存的前提。
  /// 抽成独立方法，供 `cachedPathFor` 与 `extractLocal` 复用，也便于单测只验证
  /// 「路径如何由 filePath 推导」而不触发 FFI / 存在性判定。
  Future<String> cacheFilePathFor(Track t) async =>
      p.join((await _cacheDir).path, '${_keyFor(t)}.jpg');

  /// 该曲目已缓存的封面本地路径（存在则返回，否则 null）。
  Future<String?> cachedPathFor(Track t) async {
    final f = File(await cacheFilePathFor(t));
    return f.existsSync() ? f.path : null;
  }

  /// 为本地曲目提取并缓存封面；成功返回本地路径，失败/无封面返回 null。
  /// 已缓存则直接返回，避免重复 FFI 提取。
  Future<String?> extractLocal(Track t) async {
    if (t.filePath == null) return null;
    final out = File(await cacheFilePathFor(t));
    if (await out.exists()) return out.path;
    try {
      final bytes = await frb_cover.getCoverBytes(path: t.filePath!);
      if (bytes.isEmpty) return null;
      await out.writeAsBytes(bytes);
      return out.path;
    } catch (_) {
      // 无封面 / 解析失败：静默降级为灰阶占位
      return null;
    }
  }
}

/// FNV-1a 64-bit 哈希 → 16 位十六进制字符串（确定性，跨运行稳定）。
String _fnv1a(String s) {
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
