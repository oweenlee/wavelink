import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:wavelink_mobile/data/services/subscription_service.dart';
import 'package:wavelink_mobile/ui/features/paywall/view_models/subscription_provider.dart';

/// 测试用假订阅网关：覆写 [SubscriptionGateway] 全部方法，完全不触碰
/// StoreKit / 原生通道，使订阅状态机与门控逻辑可在纯 Dart 测试环境构造。
///
/// 记录调用（[initCalled] / [purchased]）与监听器，[emit] 可主动推送权益
/// 变更，模拟 StoreKit 的交易更新回调。
class FakeGateway implements SubscriptionGateway {
  bool initCalled = false;
  int initCount = 0;

  @override
  bool configured = true;

  @override
  bool keyMissing = false;

  /// 三态权益查询：`null` 表示未知（弱网/系统延迟）
  ProEntitlement? queryProResult = const ProEntitlement();

  ProEntitlement purchaseResult = const ProEntitlement(
    plan: ProPlan.lifetime,
  );
  Object? purchaseError;
  ProductDetails? purchased;

  ProEntitlement restoreResult = const ProEntitlement(plan: ProPlan.lifetime);

  final List<void Function(ProEntitlement)> listeners = [];

  @override
  Future<void> init() async {
    initCalled = true;
    initCount++;
  }

  @override
  Future<ProEntitlement?> queryPro() async => queryProResult;

  @override
  Future<ProEntitlement> purchase(ProductDetails product) async {
    purchased = product;
    final err = purchaseError;
    if (err != null) throw err;
    return purchaseResult;
  }

  @override
  Future<ProEntitlement> restore() async => restoreResult;

  @override
  void addCustomerInfoListener(void Function(ProEntitlement) listener) {
    listeners.add(listener);
  }

  @override
  void removeCustomerInfoListener(void Function(ProEntitlement) listener) {
    listeners.remove(listener);
  }

  /// 模拟 StoreKit 推送权益变更（购买成功/过期/退款）。
  void emit(ProPlan plan) {
    for (final l in List.of(listeners)) {
      l(ProEntitlement(plan: plan));
    }
  }
}

/// 构造 [ProductDetails]（默认为买断档），供购买路径断言使用。
ProductDetails fakeProduct([
  String id = SubscriptionService.proLifetimeId,
]) =>
    ProductDetails(
      id: id,
      title: 'WaveLink Pro',
      description: '',
      price: r'$7.99',
      rawPrice: 7.99,
      currencyCode: 'USD',
    );
