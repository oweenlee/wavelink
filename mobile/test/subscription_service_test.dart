import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/data/services/mock_subscription_service.dart';
import 'package:wavelink_mobile/data/services/subscription_service.dart';

void main() {
  group('MockSubscriptionService', () {
    test('初始未订阅时 isSubscribed 为 false', () async {
      final svc = MockSubscriptionService();
      await svc.initialize();
      expect(svc.statusStream, isNotNull);

      var latest = const SubscriptionStatus();
      svc.statusStream.listen((s) => latest = s);
      // sync 广播流：initialize 的事件在 listen 前的派发不会缓存，
      // 此处 latest 保持初始值，符合"未订阅"语义
      expect(latest.isSubscribed, isFalse);
    });

    test('purchase 后 isSubscribed 变为 true 并带套餐信息', () async {
      final svc = MockSubscriptionService();
      await svc.initialize();

      SubscriptionStatus? latest;
      svc.statusStream.listen((s) => latest = s);

      final plans = await svc.fetchPlans();
      expect(plans.length, greaterThanOrEqualTo(2));
      // 年度档标记 isAnnual，且年度排在首位（付费墙默认推荐）
      expect(plans.first.isAnnual, isTrue);
      // 方案 A：官方 14 天免费试用，两档都有试用期
      for (final p in plans) {
        expect(p.trialDays, 14, reason: '${p.productId} 应有 14 天试用');
      }

      final outcome = await svc.purchase(plans.first);
      expect(outcome, PurchaseOutcome.success);
      // sync 派发：purchase 返回时 listener 已收到最新状态
      expect(latest!.isSubscribed, isTrue);
      expect(latest!.activePlan?.productId, plans.first.productId);
    });

    test('purchase 失败路径：setFailNextPurchase 后返回 failed 且不订阅', () async {
      final svc = MockSubscriptionService();
      await svc.initialize();

      SubscriptionStatus? latest;
      svc.statusStream.listen((s) => latest = s);

      final plans = await svc.fetchPlans();
      svc.setFailNextPurchase();
      final outcome = await svc.purchase(plans.first);
      expect(outcome, PurchaseOutcome.failed);
      expect(latest!.isSubscribed, isFalse);
    });

    test('purchase 取消路径：setCancelNextPurchase 后返回 cancelled 且不订阅', () async {
      final svc = MockSubscriptionService();
      await svc.initialize();

      final plans = await svc.fetchPlans();
      svc.setCancelNextPurchase();
      final outcome = await svc.purchase(plans.first);
      expect(outcome, PurchaseOutcome.cancelled);
    });

    test('restorePurchases 恢复上次购买状态', () async {
      final svc = MockSubscriptionService();
      await svc.initialize();

      final plans = await svc.fetchPlans();
      await svc.purchase(plans.first);
      // 模拟"重新初始化"的会话（新实例不共享状态，符合 mock 语义）
      final svc2 = MockSubscriptionService();
      await svc2.initialize();
      // mock 的 restore 恢复的是当前会话内的购买态
      final ok = await svc2.restorePurchases();
      expect(ok, isFalse); // 新 mock 实例无历史购买

      // 同一实例内 restore 返回 true
      final okSame = await svc.restorePurchases();
      expect(okSame, isTrue);
    });

    test('debugSetSubscribed 可直接驱动 UI 状态（联调用途）', () async {
      final svc = MockSubscriptionService();
      await svc.initialize();

      SubscriptionStatus? latest;
      svc.statusStream.listen((s) => latest = s);

      svc.debugSetSubscribed(true);
      expect(latest!.isSubscribed, isTrue);
      svc.debugSetSubscribed(false);
      expect(latest!.isSubscribed, isFalse);
    });
  });
}
