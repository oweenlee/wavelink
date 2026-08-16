import 'dart:async';
import 'subscription_service.dart';

/// 本地 Mock 订阅服务（默认实现）。
///
/// 用途：
/// - **无商店账号的本地开发**：跑通「未订阅→点击锁定功能→付费墙→模拟购买→
///   解锁」全链路，UI/锁定逻辑不依赖真实计费环境；
/// - **自动化测试**：通过构造参数注入初始订阅状态，验证 UI 分支。
///
/// 行为：
/// - `purchase` 默认立即成功（可选注入 `failNextPurchase` 模拟失败路径）；
/// - `restorePurchases` 默认恢复上次 mock 购买结果；
/// - 状态变化通过 [statusStream] 广播，与真实实现接口一致。
class MockSubscriptionService implements SubscriptionService {
  MockSubscriptionService({bool initiallySubscribed = false})
      : _subscribed = initiallySubscribed;

  bool _subscribed;
  SubscriptionPlan? _activePlan;
  // sync: 状态变更（purchase/restore/debugSetSubscribed）同步派发，
  // 与真实 RevenueCat 平台回调的即时性一致，测试无需等待异步派发。
  final _controller = StreamController<SubscriptionStatus>.broadcast(sync: true);
  bool _failNextPurchase = false;

  /// 模拟下一次购买失败（测试失败路径用，用完自动复位）。
  void setFailNextPurchase() => _failNextPurchase = true;

  /// 直接设置订阅状态（UI 联调快捷方式）。
  void debugSetSubscribed(bool value) {
    _subscribed = value;
    _emit();
  }

  void _emit() {
    _controller.add(_status());
  }

  SubscriptionStatus _status() => SubscriptionStatus(
        isSubscribed: _subscribed,
        activePlan: _activePlan,
      );

  @override
  Future<void> initialize() async {
    // mock 无需网络，直接广播当前状态
    _emit();
  }

  @override
  Future<List<SubscriptionPlan>> fetchPlans() async {
    // 与 RevenueCat 实现一致的排序：年度优先（付费墙默认推荐）
    return const [
      SubscriptionPlan(
        productId: 'wavelink_annual',
        title: '年度会员',
        priceText: '\$19.99/年',
        periodDays: 365,
        isAnnual: true,
      ),
      SubscriptionPlan(
        productId: 'wavelink_monthly',
        title: '月度会员',
        priceText: '\$2.99/月',
        periodDays: 30,
      ),
    ];
  }

  @override
  Future<bool> purchase(SubscriptionPlan plan) async {
    if (_failNextPurchase) {
      _failNextPurchase = false;
      _emit(); // 失败也广播当前状态（UI 同步"仍未订阅"）
      return false;
    }
    _subscribed = true;
    _activePlan = plan;
    _emit();
    return true;
  }

  @override
  Future<bool> restorePurchases() async {
    // mock 语义：恢复到 mock 会话内已购买状态（真实实现为商店级恢复）
    _emit();
    return _subscribed;
  }

  @override
  Stream<SubscriptionStatus> get statusStream => _controller.stream;
}
