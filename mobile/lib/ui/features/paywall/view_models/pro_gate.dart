import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import 'subscription_provider.dart';

/// Pro 功能门控：已购放行；未购且查询完成则改道付费墙。
///
/// 查询未就绪时等待完成（refresh 必然终止，失败也置 ready），不放行——
/// 否则启动窗口内未购用户可配置并持久化 Pro 功能（AutoEQ/房间校正/Bit
/// Perfect / 网络音源 应用层无订阅检查，配置持久化后永久生效，形成白嫖）。
Future<void> requirePro(
  BuildContext context,
  WidgetRef ref,
  VoidCallback action,
) async {
  await ref.read(subscriptionProvider.notifier).ensureReady();
  if (!context.mounted) return;
  final sub = ref.read(subscriptionProvider);
  if (sub.isPro) {
    action();
  } else {
    context.push('/paywall');
  }
}

/// 是否展示「PRO」徽标：仅权益查询完成且未购买时显示。
bool showProBadge(WidgetRef ref) =>
    ref.watch(subscriptionProvider.select((s) => s.ready && !s.isPro));

/// 行内「PRO」徽标：未购买（且权益查询已完成）时显示，购买后自动消失。
/// 行内只 select ready/isPro，购买完成自动刷新本行。
class ProBadge extends ConsumerWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!showProBadge(ref)) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.textTertiary.withAlpha(120)),
      ),
      child: const Text(
        'PRO',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: AppTheme.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
