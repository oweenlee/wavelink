import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// 全局动画规范：统一时长/曲线，与 mobile `AppAnim` 同规格
///（材质/节奏两端口径一致，避免各自发散）。
///
/// 性能约定（必须遵守，移动端踩坑经验平移）：
/// - 只用 fade/slide/scale/flip 等 transform+opacity 类效果（GPU 友好，
///   不触发重绘重布局）；禁止在滚动列表/高频重建路径加 blur、shadow 动画。
/// - 列表入场动画只对前 [kMaxAnimatedListIndex] 项生效：
///   ListView 懒加载回收重建会导致动画重播，滚动时闪烁且耗性能。
/// - 一次性入场效果用 Animate 自动播放；循环动画单独评估（避免常驻 ticker）。
abstract final class AppAnim {
  /// 快速微交互（图标切换、按钮态）
  static const fast = Duration(milliseconds: 180);

  /// 标准过渡（元素入场、面板切换）
  static const normal = Duration(milliseconds: 320);

  /// 页面级入场
  static const page = Duration(milliseconds: 450);

  /// 列表项交错步长（每项递增延迟，形成瀑布入场）
  static const staggerStep = Duration(milliseconds: 55);

  /// 列表项入场时长（比标准过渡更慢，入场观感更从容）
  static const listDuration = Duration(milliseconds: 560);

  static const Curve curve = Curves.easeOutCubic;
  static const Curve curveIn = Curves.easeInOutCubic;

  /// 列表入场动画最多作用的项数（超出直接返回原组件，零开销）
  static const int kMaxAnimatedListIndex = 11;

  /// 列表项入场：fade + 轻微上滑，按 index 交错延迟。
  /// index 超出 [kMaxAnimatedListIndex] 时原样返回（不构建动画）。
  static Widget listEntrance(Widget child, int index) {
    if (index > kMaxAnimatedListIndex) return child;
    final delay = staggerStep * index;
    return child
        .animate()
        .fade(duration: listDuration, curve: curve, delay: delay)
        .slideY(
          begin: 0.1,
          end: 0,
          duration: listDuration,
          curve: curve,
          delay: delay,
        );
  }

  /// 页面元素入场：fade + 上滑，可指定延迟（用于页面内 stagger 编排）。
  static Widget entrance(
    Widget child, {
    Duration delay = Duration.zero,
    double slideY = 0.08,
    Duration? duration,
  }) {
    return child
        .animate()
        .fade(duration: duration ?? page, curve: curve, delay: delay)
        .slideY(
          begin: slideY,
          end: 0,
          duration: duration ?? page,
          curve: curve,
          delay: delay,
        );
  }

  /// 元素出现：仅 fade + scale（适合卡片/封面入场，无位移）。
  static Widget popIn(Widget child, {Duration delay = Duration.zero}) {
    return child
        .animate()
        .fade(duration: normal, curve: curve, delay: delay)
        .scale(
          begin: const Offset(0.94, 0.94),
          end: const Offset(1, 1),
          duration: normal,
          curve: curve,
          delay: delay,
        );
  }
}