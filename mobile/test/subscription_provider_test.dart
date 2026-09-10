import 'package:checks/checks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/data/services/subscription_service.dart';
import 'package:wavelink_mobile/ui/features/paywall/view_models/subscription_provider.dart';

// ── Fake ──────────────────────────────────────────────────────────────────

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

  void emit(ProPlan plan) {
    for (final l in List.of(listeners)) {
      l(ProEntitlement(plan: plan));
    }
  }
}

ProductDetails _product([
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

// ── 测试 ─────────────────────────────────────────────────────────────────

void main() {
  late ProviderContainer container;
  late FakeGateway gateway;
  var revocations = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
    gateway = FakeGateway();
    revocations = 0;
    container = ProviderContainer(
      overrides: [
        subscriptionGatewayProvider.overrideWithValue(gateway),
        proRevocationHandlerProvider.overrideWithValue(
          () async => revocations++,
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  /// 预置「曾经激活过 Pro」（含最后已知档位），模拟弱网乐观恢复场景。
  Future<void> markEverActive([ProPlan plan = ProPlan.lifetime]) async {
    await PreferencesService.instance.setProEverActive(true);
    await PreferencesService.instance.setProLastPlanName(plan.name);
  }

  Future<SubscriptionState> refresh() async {
    await container.read(subscriptionProvider.notifier).refresh();
    return container.read(subscriptionProvider);
  }

  group('refresh 状态流转', () {
    test('已买断：isPro=true 且非订阅制，记录曾激活标记', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.lifetime);
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.isSubscription).isFalse();
      check(s.ready).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
      check(PreferencesService.instance.proLastPlanName).equals('lifetime');
      check(revocations).equals(0);
    });

    test('年度订阅：isPro=true 且 isSubscription=true', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.yearly);
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.isSubscription).isTrue();
      check(s.plan).equals(ProPlan.yearly);
    });

    test('月度订阅：isPro=true 且 isSubscription=true', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.monthly);
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.isSubscription).isTrue();
      check(s.plan).equals(ProPlan.monthly);
    });

    test('新用户未购买：锁定但不剥夺任何设置', () async {
      gateway.queryProResult = const ProEntitlement();
      final s = await refresh();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
    });

    test('查询未知（弱网）：按最后已知档位恢复，不剥夺', () async {
      await markEverActive(ProPlan.yearly);
      gateway.queryProResult = null;
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.plan).equals(ProPlan.yearly);
      check(revocations).equals(0);
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('查询未知且从未激活（全新用户）：维持未购买', () async {
      gateway.queryProResult = null;
      final s = await refresh();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
      check(PreferencesService.instance.proEverActive).isFalse();
    });

    test('明确未激活且曾激活（订阅到期/退款/撤销）：剥夺并清标记', () async {
      await markEverActive();
      gateway.queryProResult = const ProEntitlement();
      final s = await refresh();
      check(s.isPro).isFalse();
      check(revocations).equals(1);
      check(PreferencesService.instance.proEverActive).isFalse();
      check(PreferencesService.instance.proLastPlanName).isNull();
    });

    test('Key 未注入：静默降级，不注册监听、不剥夺', () async {
      await markEverActive();
      gateway.keyMissing = true;
      final s = await refresh();
      check(gateway.initCalled).isTrue();
      check(gateway.listeners).isEmpty();
      check(s.ready).isTrue();
      check(s.isPro).isFalse();
      check(revocations).equals(0);
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('configure 失败：同样静默降级不剥夺', () async {
      await markEverActive();
      gateway.configured = false;
      final s = await refresh();
      check(gateway.listeners).isEmpty();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
    });
  });

  group('权益变更监听', () {
    test('refresh 后注册监听；订阅到期即时剥夺', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.monthly);
      await refresh();
      check(gateway.listeners).length.equals(1);
      check(container.read(subscriptionProvider).isSubscription).isTrue();

      gateway.emit(ProPlan.none);
      check(container.read(subscriptionProvider).isPro).isFalse();
      check(revocations).equals(1);
      check(PreferencesService.instance.proEverActive).isFalse();
    });

    test('重复回调保持幂等：不重复剥夺', () async {
      await markEverActive();
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.yearly);
      await refresh();

      gateway.emit(ProPlan.none);
      gateway.emit(ProPlan.none);
      check(revocations).equals(1);
    });

    test('撤销后重新购买恢复 Pro', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.lifetime);
      await refresh();
      gateway.emit(ProPlan.none);
      gateway.emit(ProPlan.lifetime);
      check(container.read(subscriptionProvider).isPro).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('refresh 幂等：并发调用共享同一 Future（init 只跑一次）', () async {
      gateway.queryProResult = const ProEntitlement();
      final f1 = container.read(subscriptionProvider.notifier).refresh();
      final f2 = container.read(subscriptionProvider.notifier).refresh();
      await Future.wait([f1, f2]);
      check(gateway.initCount).equals(1);
      check(container.read(subscriptionProvider).ready).isTrue();
    });

    test('ensureReady：未就绪时等待 refresh 完成，就绪后直接返回', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.lifetime);
      final readyFuture = container
          .read(subscriptionProvider.notifier)
          .ensureReady();
      // await 前 state 仍未就绪
      check(container.read(subscriptionProvider).ready).isFalse();
      await readyFuture;
      check(container.read(subscriptionProvider).ready).isTrue();
      check(container.read(subscriptionProvider).isPro).isTrue();
      // 已就绪后再次调用立即返回
      await container.read(subscriptionProvider.notifier).ensureReady();
      check(gateway.initCount).equals(1);
    });

    test('容器销毁时注销监听', () async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.yearly);
      await refresh();
      check(gateway.listeners).length.equals(1);
      container.dispose();
      check(gateway.listeners).isEmpty();
    });
  });

  group('购买 / 恢复购买', () {
    test('买断成功：置位 Pro 与标记', () async {
      gateway.queryProResult = const ProEntitlement();
      await refresh();
      final result = await container
          .read(subscriptionProvider.notifier)
          .purchase(_product());
      check(result.isPro).isTrue();
      check(result.isSubscription).isFalse();
      check(gateway.purchased).isNotNull();
      check(container.read(subscriptionProvider).isPro).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('订阅购买成功：标记为订阅制', () async {
      gateway.purchaseResult = const ProEntitlement(plan: ProPlan.yearly);
      final result = await container
          .read(subscriptionProvider.notifier)
          .purchase(_product(SubscriptionService.proYearlyId));
      check(result.isPro).isTrue();
      check(result.isSubscription).isTrue();
      check(container.read(subscriptionProvider).plan).equals(ProPlan.yearly);
    });

    test('购买未授予权益（用户取消）：状态不变', () async {
      gateway.purchaseResult = const ProEntitlement();
      final result = await container
          .read(subscriptionProvider.notifier)
          .purchase(_product());
      check(result.isPro).isFalse();
      check(container.read(subscriptionProvider).isPro).isFalse();
    });

    test('原生错误向上传播（由调用方区分用户取消）', () async {
      gateway.purchaseError = PlatformException(
        code: '2',
        message: 'purchaseCancelledError',
      );
      await check(
        container.read(subscriptionProvider.notifier).purchase(_product()),
      ).throws<PlatformException>();
      check(container.read(subscriptionProvider).isPro).isFalse();
    });

    test('恢复成功：置位；恢复为空：状态不变', () async {
      gateway.restoreResult = const ProEntitlement(plan: ProPlan.monthly);
      final restored = await container
          .read(subscriptionProvider.notifier)
          .restore();
      check(restored.isPro).isTrue();
      check(restored.plan).equals(ProPlan.monthly);
      check(container.read(subscriptionProvider).isPro).isTrue();

      gateway.restoreResult = const ProEntitlement();
      check(
        (await container.read(subscriptionProvider.notifier).restore()).isPro,
      ).isFalse();
    });
  });

  group('产品 ID 与档位映射', () {
    test('三个产品 ID 映射到对应档位', () {
      check(SubscriptionService.planOf(SubscriptionService.proMonthlyId))
          .equals(ProPlan.monthly);
      check(SubscriptionService.planOf(SubscriptionService.proYearlyId))
          .equals(ProPlan.yearly);
      check(SubscriptionService.planOf(SubscriptionService.proLifetimeId))
          .equals(ProPlan.lifetime);
      check(SubscriptionService.planOf('unknown_product'))
          .equals(ProPlan.none);
    });

    test('订阅制判定：月/年为订阅，买断不是', () {
      check(
        SubscriptionService.isSubscriptionId(SubscriptionService.proMonthlyId),
      ).isTrue();
      check(
        SubscriptionService.isSubscriptionId(SubscriptionService.proYearlyId),
      ).isTrue();
      check(
        SubscriptionService.isSubscriptionId(SubscriptionService.proLifetimeId),
      ).isFalse();
    });
  });
}
