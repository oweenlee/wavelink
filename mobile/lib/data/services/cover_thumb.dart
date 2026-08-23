import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 封面缩略图工具（对齐 desktop `CoverCache.ensureThumb`）。
///
/// NAS/本地封面缓存存的是原图（常 1~5MB JPEG），列表行直接
/// `Image.file` 渲染时每行都要整读原图磁盘 IO，滚动即卡顿。
/// 落盘原图时同步生成 `<原图路径>.thumb.jpg`（320px JPEG，
/// ~30-60KB），列表小幅展示优先读缩略图。
class CoverThumb {
  CoverThumb._();

  /// 缩略图目标边长（px）：列表行/网格卡共用，≤该尺寸的 UI 均读缩略图。
  static const int thumbSize = 320;

  /// 缩略图文件路径（命名派生：`<原图路径>.thumb.jpg`）。
  static String thumbPathFor(String fullPath) => '$fullPath.thumb.jpg';

  /// 缩略图生成串行链：解码/编码有 CPU 开销，批量写封面（扫描导入
  /// 数百首）时逐个排队后台生成，不阻塞写入方、不并发打满引擎线程。
  static Future<void> _chain = Future.value();

  /// 写入封面原图并后台生成缩略图（调用方无需关心缩略图何时就绪，
  /// 未就绪期间列表回退读原图，行为与旧版一致）。
  static Future<File> writeCover(File file, Uint8List bytes) async {
    await file.writeAsBytes(bytes);
    scheduleThumb(file, bytes: bytes);
    return file;
  }

  /// 排队生成缩略图（串行、不阻塞调用方）。
  static void scheduleThumb(File fullFile, {Uint8List? bytes}) {
    _chain = _chain.then((_) => ensureThumb(fullFile, bytes: bytes));
  }

  /// 确保原图 [fullFile] 有缩略图；已存在直接返回。
  /// [bytes] 为刚写盘的原始字节时可传入避免重复读盘。
  /// `.part` + rename 原子落盘；解码/编码失败静默（UI 回退原图）。
  static Future<void> ensureThumb(File fullFile, {Uint8List? bytes}) async {
    final thumbFile = File(thumbPathFor(fullFile.path));
    if (await thumbFile.exists()) return;
    try {
      final data = bytes ?? await fullFile.readAsBytes();
      if (data.isEmpty) return;
      // 只给 targetWidth：等比缩放（封面基本为方形）
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: thumbSize,
      );
      final frame = await codec.getNextFrame();
      if (frame.image.width == 0 || frame.image.height == 0) return;
      final raw =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
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
      // 解码/编码失败：缩略图可无，UI 回退原图
    }
  }

  /// 删除原图及配套缩略图（缓存清理用，避免残留孤儿 .thumb.jpg）。
  static Future<void> deleteWithThumb(String fullPath) async {
    try {
      final full = File(fullPath);
      if (await full.exists()) await full.delete();
      final thumb = File(thumbPathFor(fullPath));
      if (await thumb.exists()) await thumb.delete();
    } catch (_) {}
  }
}
