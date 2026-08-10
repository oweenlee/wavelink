import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 极简分级日志：统一格式 `HH:mm:ss.SSS [TAG] LEVEL: 内容`，
/// 用于快速定位问题（时间戳对齐事件顺序，级别过滤噪音）。
///
/// 输出双通道：
/// - debugPrint（flutter run 控制台 / adb logcat / Xcode 均可见）；
/// - 落盘 ring buffer：Documents/.logs/wavelink.log，超 512KB 轮转为
///   wavelink.log.old（旧文件覆盖），总量上限约 1MB。经 [init] 启用，
///   未初始化（如纯 Dart 测试环境）只走 debugPrint。
///
/// release 包丢弃 D 级，只保留 I/W/E，避免刷屏。
abstract final class Log {
  static const _d = 0, _i = 1, _w = 2, _e = 3;

  /// release 构建只保留 info 及以上
  static final int _minLevel = kReleaseMode ? _i : _d;

  // ── 落盘：缓冲 + 串行写，不阻塞调用方 ──

  static const _dirName = '.logs';
  static const _fileName = 'wavelink.log';
  static const _maxBytes = 512 * 1024;

  static File? _logFile;
  static final List<String> _pending = [];
  static bool _flushing = false;

  /// 调试跟踪（默认级别：流程节点、状态变化）
  static void d(String tag, Object? msg) => _write(_d, 'D', tag, msg);

  /// 关键节点（连接建立、导入完成等值得长期保留的信息）
  static void i(String tag, Object? msg) => _write(_i, 'I', tag, msg);

  /// 可自愈的异常（重试、降级、跳过）
  static void w(String tag, Object? msg) => _write(_w, 'W', tag, msg);

  /// 失败/错误。可附加异常对象与堆栈
  static void e(String tag, Object? msg, [Object? error, StackTrace? st]) {
    _write(_e, 'E', tag, msg);
    if (error != null) _write(_e, 'E', tag, '  ↳ $error');
    if (st != null) {
      for (final line in st.toString().trim().split('\n').take(8)) {
        _write(_e, 'E', tag, '  ↳ $line');
      }
    }
  }

  static void _write(int level, String mark, String tag, Object? msg) {
    if (level < _minLevel) return;
    final line = '${_ts()} [$tag] $mark: $msg';
    debugPrint(line);
    // 落盘进缓冲，微任务批处理写入：同一轮事件循环内的多条日志
    // 合并成一次磁盘 IO；App 被杀最多丢当前微任务前的几条。
    _pending.add(line);
    if (_logFile != null) _scheduleFlush();
  }

  /// 启用落盘（main 启动时调一次）。失败静默降级为纯 debugPrint。
  static Future<void> init() async {
    try {
      final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/$_dirName',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      _logFile = File('${dir.path}/$_fileName');
      _scheduleFlush(); // 把 init 前累积的启动日志一并写入
    } catch (e) {
      debugPrint('Log init 失败，仅控制台输出: $e');
    }
  }

  /// 日志文件总字节（当前 + 轮转旧文件，诊断页展示用）
  static Future<int> totalBytes() async {
    final f = _logFile;
    if (f == null) return 0;
    var n = 0;
    for (final p in [f.path, '${f.path}.old']) {
      final file = File(p);
      if (await file.exists()) n += await file.length();
    }
    return n;
  }

  /// 清空日志文件（诊断页管理入口）
  static Future<void> clear() async {
    final f = _logFile;
    if (f == null) return;
    for (final p in [f.path, '${f.path}.old']) {
      final file = File(p);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  static void _scheduleFlush() {
    if (_flushing) return;
    _flushing = true;
    scheduleMicrotask(() async {
      try {
        await _flush();
      } catch (e) {
        debugPrint('Log 落盘失败: $e');
      } finally {
        _flushing = false;
        // 微任务排队期间又新来的日志，再排一轮
        if (_pending.isNotEmpty) _scheduleFlush();
      }
    });
  }

  static Future<void> _flush() async {
    final f = _logFile;
    if (f == null || _pending.isEmpty) return;
    final buf = List<String>.of(_pending);
    _pending.clear();
    // 超限轮转：旧文件覆盖丢弃（ring buffer 语义，总量上限约 2×512KB）
    if (await f.exists() && await f.length() > _maxBytes) {
      final old = File('${f.path}.old');
      if (await old.exists()) await old.delete();
      await f.rename(old.path);
    }
    await f.writeAsString('${buf.join('\n')}\n', mode: FileMode.append);
  }

  static String _ts() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${three(now.millisecond)}';
  }
}
