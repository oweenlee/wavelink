import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../../data/services/subscription_service.dart';

/// 订阅状态（AsyncNotifier：启动时异步查询一次，购买/恢复后手动刷新）。
class SubscriptionState {
  /// 是否拥有 Pro 权益。
  final bool isPro;

  /// 首次查询是否完成（完成前门控行为保持放行，避免启动闪付费墙）。
  final bool ready;

  const SubscriptionState({this.isPro = false, this.ready = false});

  SubscriptionState copyWith({bool? isPro, bool? ready}) =>
      SubscriptionState(isPro: isPro ?? this.isPro, ready: ready ?? this.ready);
}

class SubscriptionNotifier extends Notifier<SubscriptionState> {
  @override
  SubscriptionState build() => const SubscriptionState();

  /// 启动时调用一次：查询当前权益。
  Future<void> refresh() async {
    final pro = await SubscriptionService.isPro();
    state = state.copyWith(isPro: pro, ready: true);
  }

  /// 购买套餐。返回是否成功成为 Pro。
  Future<bool> purchase(Package package) async {
    final ok = await SubscriptionService.purchase(package);
    if (ok) state = state.copyWith(isPro: true, ready: true);
    return ok;
  }

  /// 恢复购买。返回是否恢复出 Pro 权益。
  Future<bool> restore() async {
    final ok = await SubscriptionService.restore();
    if (ok) state = state.copyWith(isPro: true, ready: true);
    return ok;
  }
}

final subscriptionProvider =
    NotifierProvider<SubscriptionNotifier, SubscriptionState>(
      SubscriptionNotifier.new,
    );
