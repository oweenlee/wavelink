import 'package:flutter/foundation.dart';

/// 极简分级日志：统一格式 `HH:mm:ss.SSS [TAG] LEVEL: 内容`，
/// 用于快速定位问题（时间戳对齐事件顺序，级别过滤噪音）。
///
/// 输出走 debugPrint（flutter run 控制台 / adb logcat / Xcode
/// 均可见）。release 包丢弃 D 级，只保留 I/W/E，避免刷屏。
/// 后续如需落盘导出或上报，只需替换 [_emit] 一处。
abstract final class Log {
  static const _d = 0, _i = 1, _w = 2, _e = 3;

  /// release 构建只保留 info 及以上
  static final int _minLevel = kReleaseMode ? _i : _d;

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
    _emit('${_ts()} [$tag] $mark: $msg');
  }

  static void _emit(String line) => debugPrint(line);

  static String _ts() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${three(now.millisecond)}';
  }
}
