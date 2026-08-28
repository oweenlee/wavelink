/// 通用 UI 格式化辅助（与 mobile 端工具函数对齐，供各 screen/widget 复用）。
library;

/// `m:ss` 时间码（用于列表时长、进度条读数等；等宽场景配 WlText.mono）。
String fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 文件体积（1024 进制，保留 1 位小数；不足 1 KB 直接给字节数）。
/// 用于详情页面等需要真实文件大小的读数场景。
String fmtBytes(int? bytes) {
  if (bytes == null || bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
