import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../src/rust/api/cover.dart' as frb_cover;
import '../src/rust/api/smb.dart' as frb_smb;
import '../src/rust/api/webdav.dart' as frb_webdav;
import 'nas_service.dart';
import 'stable_hash.dart';
import 'subsonic_service.dart';
import 'webdav_service.dart';

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
    // 目录可能被外部删除（设置页「清空所有数据」删除 .covers）：缓存的
    // _dir 若已失效必须重建，否则后续 writeCover 写进不存在的父目录直接
    // 抛 FileSystemException（被静默吞掉）→ 封面永远写不进去，表现为
    // 「清空数据后重新添加音乐，封面图不展示」。existsSync 是廉价 stat，
    // 热路径可接受。
    if (_dir != null && _dir!.existsSync()) return _dir!;
    final appDir = await getApplicationDocumentsDirectory();
    _dir = Directory(p.join(appDir.path, '.covers'));
    if (!_dir!.existsSync()) await _dir!.create(recursive: true);
    return _dir!;
  }

  /// 稳定缓存键：filePath 的 FNV-1a 十六进制（跨运行一致）。
  String _keyFor(Track t) =>
      t.filePath != null ? fnv1a(t.filePath!) : t.id;

  /// 缩略图目标边长（px）：列表行/网格卡共用同一张，≤该尺寸的 UI 均读缩略图，
  /// 大图场景（正在播放页等）仍读原图。JPEG quality 80，平均 ~30-60KB。
  static const int thumbSize = 320;

  /// 缩略图文件路径（命名派生：`<原图路径>.thumb.jpg`，避免模型/DB 变更）。
  static String thumbPathFor(String fullPath) => '$fullPath.thumb.jpg';

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

  /// 写入封面缓存（原图 + 320px JPEG 缩略图），返回缓存路径。
  /// 统一入口：扫描期种子（library.dart）与三个 extract* 都走这里，
  /// 保证新落盘的封面都带缩略图；原图已存在只补缩略图。
  /// 失败（解码异常/编码异常）静默：UI 侧 errorBuilder 回退原图。
  Future<String?> writeCover(Track probe, Uint8List bytes) async {
    try {
      final out = File(await cacheFilePathFor(probe));
      if (!await out.exists()) {
        await out.writeAsBytes(bytes);
      }
      // 直接复用内存 bytes 生成缩略图，避免刚写完又读一遍原图。
      await ensureThumb(out, bytes: bytes);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// 确保 [fullFile] 有缩略图；已存在直接返回。
  /// 缩略图只读一次原图（~1-3MB）后经原生解码到 320px 再 JPEG 编码。
  /// `.part` + rename 原子落盘：失败不留下损坏的 .thumb.jpg 被误判"已生成"。
  Future<void> ensureThumb(File fullFile, {Uint8List? bytes}) async {
    final thumbFile = File(thumbPathFor(fullFile.path));
    if (await thumbFile.exists()) return;
    try {
      final data = bytes ?? await fullFile.readAsBytes();
      if (data.isEmpty) return;
      final codec = await ui.instantiateImageCodec(
        data,
        // 只给 targetWidth：同时给宽高会强制拉伸到精确尺寸（非等比缩放）；
        // 单独给宽度则等比缩放（封面基本为方形，等比缩放到 320 宽即可）。
        targetWidth: thumbSize,
      );
      final frame = await codec.getNextFrame();
      if (frame.image.width == 0 || frame.image.height == 0) return;
      final raw = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) return;
      final decoded = img.Image.fromBytes(
        width: frame.image.width,
        height: frame.image.height,
        bytes: raw.buffer,
        order: img.ChannelOrder.rgba,
      );
      final jpg = img.encodeJpg(decoded, quality: 80);
      final part = File('${thumbFile.path}.part');
      await part.writeAsBytes(jpg, flush: true);
      await part.rename(thumbFile.path);
    } catch (_) {
      // 解码/编码失败：缩略图可无，UI 回退原图。
    }
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
      return writeCover(t, bytes);
    } catch (_) {
      // 无封面 / 解析失败：静默降级为灰阶占位
      return null;
    }
  }

  /// 为 NAS (SMB) 曲目提取并缓存封面：远程拉取文件头/尾字节 → lofty 内存解析。
  /// 已缓存则直接返回，避免重复网络拉取。成功返回本地路径，失败/无封面返回 null。
  ///
  /// 内嵌封面位置因容器而异：MP3(ID3v2)/FLAC(头 metadata)/OGG 在头部；
  /// M4A 的 moov 可能在文件尾（mdat 在前）。因此先试头 4MB，失败再试尾 4MB。
  static const int _remoteProbeBytes = 4 * 1024 * 1024;

  Future<String?> extractNas(Track t) async {
    if (t.remotePath == null) return null;
    final out = File(await cacheFilePathFor(t));
    if (await out.exists()) return out.path;
    final sw = Stopwatch()..start();
    // 确保 SMB 会话可用（内部 keepalive 探测，不健康则重建）
    final connErr = await NasService.connect();
    if (connErr != null) {
      debugPrint('[cover] nas ${t.id}: connect 失败 ($connErr)');
      return null;
    }
    final maxLen = BigInt.from(_remoteProbeBytes);
    try {
      final head = await frb_smb.smbReadHead(
          path: t.remotePath!, maxLen: maxLen);
      final headCover = await _coverFromBytes(head);
      if (headCover != null) {
        final p = await writeCover(t, headCover);
        debugPrint(
            '[cover] nas ${t.id}: head ${head.length}B '
            'cover=${headCover.length}B ${sw.elapsedMilliseconds}ms → $p');
        return p;
      }
      final tail = await frb_smb.smbReadTail(
          path: t.remotePath!, maxLen: maxLen);
      final tailCover = await _coverFromBytes(tail);
      if (tailCover != null) {
        final p = await writeCover(t, tailCover);
        debugPrint(
            '[cover] nas ${t.id}: tail ${tail.length}B '
            'cover=${tailCover.length}B ${sw.elapsedMilliseconds}ms → $p');
        return p;
      }
      // 头/尾截断均解析失败（WAV 等容器要求完整文件，diag 实证头部 4MB
      // 截断时 lofty 直接报 data chunk 缺失）→ ≤30MB 整文件下载窦底
      //（对齐 mobile `_fetchCoverByFullDownload`；下载本就会入播放缓存，
      // 不用白不下）。
      int? size = t.fileSize;
      try {
        size = (await frb_smb.smbFileSize(path: t.remotePath!)).toInt();
      } catch (_) {
        // 探测失败回退曲目已知大小
      }
      if (size != null && size > 0 && size <= 30 * 1024 * 1024) {
        final local = await NasService.downloadToLocal(t);
        if (local != null) {
          final fullCover = await _coverFromBytes(await File(local).readAsBytes());
          if (fullCover != null) {
            final p = await writeCover(t, fullCover);
            debugPrint(
                '[cover] nas ${t.id}: 整文件窦底 ${size}B '
                'cover=${fullCover.length}B ${sw.elapsedMilliseconds}ms → $p');
            return p;
          }
        }
      }
      debugPrint(
          '[cover] nas ${t.id}: 无封面（head/tail/full 均无）'
          ' ${sw.elapsedMilliseconds}ms');
      return null;
    } catch (e) {
      debugPrint(
          '[cover] nas ${t.id}: 失败 ${sw.elapsedMilliseconds}ms: $e');
      return null;
    }
  }

  /// 为 WebDAV 曲目提取并缓存封面（对齐 mobile `fetchRemoteCover`：
  /// Range 读头 → 读尾 → 头尾拼接窦底；moov 跨窗口时头尾各自难解析）。
  /// 已缓存则直接返回。
  Future<String?> extractWebdav(Track t) async {
    final davPath = t.remotePath;
    if (davPath == null) return null;
    final out = File(await cacheFilePathFor(t));
    if (await out.exists()) return out.path;
    final url = WebdavService.fullUrlFor(davPath);
    if (url == null) return null;
    // 4MB：与 Rust 侧 RANGE_READ_CAP 对齐（服务器忽略 Range 时也不拉满整曲）
    final maxLen = BigInt.from(4 * 1024 * 1024);
    final user = WebdavService.username;
    final pass = WebdavService.password;
    try {
      final head = await frb_webdav.engineReadWebdavRange(
          url: url, username: user, password: pass, maxLen: maxLen, suffix: false);
      final headCover = await _coverFromBytes(head);
      if (headCover != null) return writeCover(t, headCover);
      final tail = await frb_webdav.engineReadWebdavRange(
          url: url, username: user, password: pass, maxLen: maxLen, suffix: true);
      final tailCover = await _coverFromBytes(tail);
      if (tailCover != null) return writeCover(t, tailCover);
      // 头尾各自解析失败：拼接窦底（与 mobile 一致）
      if (head.isNotEmpty && tail.isNotEmpty) {
        final merged = await _coverFromBytes(
            Uint8List.fromList([...head, ...tail]));
        if (merged != null) return writeCover(t, merged);
      }
      return null;
    } catch (e) {
      debugPrint('[cover] webdav ${t.id}: 失败: $e');
      return null;
    }
  }

  /// 为 Subsonic 曲目下载并缓存封面：Subsonic 封面是远程 URL（含会过期的
  /// 鉴权 token），必须下载到本地缓存，否则数小时后 token 失效 → 封面 401。
  /// 用 [SubsonicService.coverUrlFor] 取最新鉴权地址。已缓存则直接返回。
  /// 封面是 JPEG 小文件，直接整读进内存（与 extractLocal/extractNas 一致）。
  Future<String?> extractSubsonic(Track t) async {
    final url = SubsonicService.coverUrlFor(t);
    if (url == null) return null;
    final out = File(await cacheFilePathFor(t));
    if (await out.exists()) return out.path;
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      if (resp.bodyBytes.isEmpty) return null;
      return writeCover(t, Uint8List.fromList(resp.bodyBytes));
    } catch (_) {
      // 网络/解析失败：静默降级为灰阶占位
      return null;
    }
  }

  /// 尝试从字节解析内嵌封面；无封面或解析失败返回 null。
  static Future<Uint8List?> _coverFromBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    try {
      final cover = await frb_cover.getCoverBytesFromMemory(data: bytes);
      return cover.isEmpty ? null : cover;
    } catch (_) {
      return null;
    }
  }
}
