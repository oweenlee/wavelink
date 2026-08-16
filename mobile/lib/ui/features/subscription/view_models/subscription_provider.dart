import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/services/mock_subscription_service.dart';
import '../../../../data/services/revenuecat_subscription_service.dart';
import '../../../../data/services/subscription_service.dart';

/// 订阅服务实现选择。
///
/// 默认 mock（本地开发/测试，无需商店账号即可跑通全链路）；
/// 发布构建/真实计费用：
/// `flutter run --dart-define=SUBSCRIPTION_BACKEND=revenuecat \
///              --dart-define=REVENUECAT_PUBLIC_API_KEY={key}`
const _backend = String.fromEnvironment('SUBSCRIPTION_BACKEND',
    defaultValue: 'mock');
const _rcApiKey = String.fromEnvironment('REVENUECAT_PUBLIC_API_KEY');

/// 订阅服务单例（生命周期与容器一致）。
final subscriptionServiceProvider = Provider<SubscriptionService>((ref) {
  if (_backend == 'revenuecat') {
    assert(
      _rcApiKey.isNotEmpty,
      'SUBSCRIPTION_BACKEND=revenuecat 需要 REVENUECAT_PUBLIC_API_KEY',
    );
    return RevenueCatSubscriptionService(publicApiKey: _rcApiKey);
  }
  return MockSubscriptionService();
});

/// 订阅状态 Provider。
///
/// - 启动时 [initialize] 拉取套餐 + 订阅状态；
/// - 监听底层服务状态流，购买/恢复/失效自动同步；
/// - [purchase]/[restore] 供付费墙调用。
class SubscriptionNotifier extends Notifier<SubscriptionStatus> {
  StreamSubscription<SubscriptionStatus>? _sub;

  SubscriptionService get _service => ref.read(subscriptionServiceProvider);

  @override
  SubscriptionStatus build() {
    // 首次 build 即订阅状态流（购买/恢复/失效自动同步）
    _sub ??= _service.statusStream.listen(
      (s) => state = s,
      onError: (Object e) =>
          state = state.copyWith(error: '$e', isLoading: false),
    );
    ref.onDispose(() => _sub?.cancel());
    unawaited(initialize());
    return const SubscriptionStatus(isLoading: true);
  }

  /// 初始化：拉套餐 + 订阅状态。
  Future<void> initialize() async {
    try {
      await _service.initialize();
      // 套餐拉取后并入 state（响应式，付费墙 watch state 即自动刷新）
      final plans = await _service.fetchPlans();
      state = state.copyWith(
        plans: plans,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '$e',
      );
    }
  }

  /// 可购买的套餐列表（默认年度在前）。
  List<SubscriptionPlan> get plans => state.plans;

  /// 发起购买。返回购买结局（成功/用户取消/失败）。
  Future<PurchaseOutcome> purchase(SubscriptionPlan plan) async {
    state = state.copyWith(isLoading: true, clearError: true);
    final outcome = await _service.purchase(plan);
    // 购买失败/用户取消：状态流已同步，这里只清除 loading
    state = state.copyWith(isLoading: false, clearError: true);
    return outcome;
  }

  /// 恢复购买。返回是否已恢复订阅。
  Future<bool> restore() async {
    state = state.copyWith(isLoading: true, clearError: true);
    final ok = await _service.restorePurchases();
    state = state.copyWith(isLoading: false, clearError: true);
    return ok;
  }

  /// 是否有权使用付费功能。
  bool canAccess() => state.isSubscribed;
}

final subscriptionProvider =
    NotifierProvider<SubscriptionNotifier, SubscriptionStatus>(
  SubscriptionNotifier.new,
);
