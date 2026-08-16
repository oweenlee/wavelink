import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'subscription_provider.dart';

/// 付费功能守卫：未订阅时跳转付费墙，并提示「此功能需要订阅」。
///
/// 用法（在需要锁定的 onTap 里）：
/// ```dart
/// onTap: () {
///   if (!ensureSubscribed(context, ref)) return;
///   // ... 原有逻辑
/// }
/// ```
/// 返回 true 表示已订阅/可继续；false 表示已拦截并跳转付费墙。
bool ensureSubscribed(BuildContext context, WidgetRef ref) {
  if (ref.read(subscriptionProvider).isSubscribed) return true;
  // 轻震动反馈提示拦截
  HapticFeedback.lightImpact();
  context.push('/paywall');
  return false;
}
