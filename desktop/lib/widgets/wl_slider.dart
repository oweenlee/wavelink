import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 统一 Slider 主题（对齐 mobile `ui/core/widgets/progress_slider_widget.dart`
/// 「滑块样式单源」的思路）。此前进度条 / 传输栏 seek 条 / 音量条三处
/// 内联 SliderThemeData，颜色与轨道高度组合重复。
///
/// - 播放域传 [color] = AccentScope 动态强调色；
/// - 非播放域（音量）传中性色（如 [AppTheme.textPrimary]）。
SliderThemeData wlSliderTheme({
  required Color color,
  double trackHeight = 3,
  double thumbRadius = 6,
  Color inactiveColor = AppTheme.s3,
  double overlayRadius = 0,
}) {
  return SliderThemeData(
    thumbColor: color,
    activeTrackColor: color,
    inactiveTrackColor: inactiveColor,
    trackHeight: trackHeight,
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
    // 去掉拖动时的默认交互光环（material 的「按压环」很出戏）；
    // 设置页等表单滑块可传 overlayRadius 保留可点热区提示。
    overlayShape: RoundSliderOverlayShape(overlayRadius: overlayRadius),
  );
}
