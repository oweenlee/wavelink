/// 通用 UI 格式化辅助（与 mobile 端工具函数对齐，供各 screen/widget 复用）。
library;

/// `m:ss` 时间码（用于列表时长、进度条读数等；等宽场景配 WlText.mono）。
String fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}
