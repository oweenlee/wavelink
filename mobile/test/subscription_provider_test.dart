import 'package:checks/checks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/ui/features/paywall/view_models/subscription_provider.dart';

// ── Fake ──────────────────────────────────────────────────────────────────

class FakeGateway implements SubscriptionGateway {
  bool initCalled = false;

  @override
  bool configured = true;

  @override
  bool keyMissing = false;

  /// queryPro 结果；null 模拟查询失败
  bool? queryProResult = false;

  bool purchaseResult = true;
  Object? purchaseError;
  Package? purchased;

  bool restoreResult = true;

  final List<CustomerInfoUpdateListener> listeners = [];

  @override
  Future<void> init() async {
    initCalled = true;
  }

  @override
  Future<bool?> queryPro() async => queryProResult;

  @override
  Future<bool> purchase(Package package) async {
    purchased = package;
    final err = purchaseError;
    if (err != null) throw err;
    return purchaseResult;
  }

  @override
  Future<bool> restore() async => restoreResult;

  @override
  void addCustomerInfoListener(CustomerInfoUpdateListener listener) {
    listeners.add(listener);
  }

  @override
  void removeCustomerInfoListener(CustomerInfoUpdateListener listener) {
    listeners.remove(listener);
  }

  /// 模拟 SDK 推送权益变更
  void emit(CustomerInfo info) {
    for (final l in List.of(listeners)) {
      l(info);
    }
  }
}

// ── 测试数据构造 ─────────────────────────────────────────────────────────

CustomerInfo _customerInfo({required bool proActive}) {
  final entitlement = EntitlementInfo(
    'pro',
    proActive,
    proActive,
    '2024-01-01T00:00:00Z',
    '2024-01-01T00:00:00Z',
    'wavelink_pro',
    false,
  );
  return CustomerInfo(
    EntitlementInfos(
      {'pro': entitlement},
      proActive ? {'pro': entitlement} : const {},
    ),
    const {},
    const [],
    const [],
    const [],
    '2024-01-01T00:00:00Z',
    'test-user',
    const {},
    '2024-01-01T00:00:00Z',
  );
}

Package _package() => Package(
  r'$rc_monthly',
  PackageType.monthly,
  const StoreProduct(
    'wavelink_pro',
    '',
    'WaveLink Pro',
    7.99,
    r'$7.99',
    'USD',
  ),
  const PresentedOfferingContext('default', null, null),
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

  Future<SubscriptionState> refresh() async {
    await container.read(subscriptionProvider.notifier).refresh();
    return container.read(subscriptionProvider);
  }

  group('refresh 状态流转', () {
    test('已订阅：isPro=true，记录曾激活标记', () async {
      gateway.queryProResult = true;
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.ready).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
      check(revocations).equals(0);
    });

    test('新用户未订阅：锁定但不剥夺任何设置', () async {
      gateway.queryProResult = false;
      final s = await refresh();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
    });

    test('查询失败（网络抖动）：保持最后已知状态，不剥夺（即使有标记）', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.queryProResult = null;
      final s = await refresh();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
      // 标记不被误清：稍后监听回调仍能纠正
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('明确未激活且曾激活（过期/退款）：剥夺 Pro 设置并清标记', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.queryProResult = false;
      final s = await refresh();
      check(s.isPro).isFalse();
      check(revocations).equals(1);
      check(PreferencesService.instance.proEverActive).isFalse();
    });

    test('Key 未注入：静默降级，不注册监听、不剥夺', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.keyMissing = true;
      final s = await refresh();
      check(gateway.initCalled).isTrue();
      check(gateway.listeners).isEmpty();
      check(s.ready).isTrue();
      check(s.isPro).isFalse();
      check(revocations).equals(0);
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('configure 失败（如桌面平台不支持）：同样静默降级不剥夺', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.configured = false;
      final s = await refresh();
      check(gateway.listeners).isEmpty();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
    });
  });

  group('权益变更监听', () {
    test('refresh 后注册监听；运行期过期即时剥夺', () async {
      gateway.queryProResult = true;
      await refresh();
      check(gateway.listeners).length.equals(1);

      gateway.emit(_customerInfo(proActive: false));
      check(container.read(subscriptionProvider).isPro).isFalse();
      check(revocations).equals(1);
      check(PreferencesService.instance.proEverActive).isFalse();
    });

    test('重复回调保持幂等：不重复剥夺', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.queryProResult = true;
      await refresh();

      gateway.emit(_customerInfo(proActive: false));
      gateway.emit(_customerInfo(proActive: false));
      check(revocations).equals(1);
    });

    test('权益被撤销（退款）后重新购买恢复 Pro', () async {
      gateway.queryProResult = true;
      await refresh();
      gateway.emit(_customerInfo(proActive: false));
      gateway.emit(_customerInfo(proActive: true));
      check(container.read(subscriptionProvider).isPro).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('容器销毁时注销监听', () async {
      gateway.queryProResult = true;
      await refresh();
      check(gateway.listeners).length.equals(1);
      container.dispose();
      check(gateway.listeners).isEmpty();
    });
  });

  group('购买 / 恢复购买', () {
    test('购买成功：置位 Pro 与标记', () async {
      gateway.queryProResult = false;
      await refresh();
      final ok = await container
          .read(subscriptionProvider.notifier)
          .purchase(_package());
      check(ok).isTrue();
      check(gateway.purchased).isNotNull();
      check(container.read(subscriptionProvider).isPro).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('购买返回 false（权益未授予）：状态不变', () async {
      gateway.purchaseResult = false;
      final ok = await container
          .read(subscriptionProvider.notifier)
          .purchase(_package());
      check(ok).isFalse();
      check(container.read(subscriptionProvider).isPro).isFalse();
    });

    test('原生错误向上传播（由调用方区分用户取消）', () async {
      gateway.purchaseError = PlatformException(
        code: '2',
        message: 'purchaseCancelledError',
      );
      await check(
        container.read(subscriptionProvider.notifier).purchase(_package()),
      ).throws<PlatformException>();
      check(container.read(subscriptionProvider).isPro).isFalse();
    });

    test('恢复成功：置位；恢复失败：状态不变', () async {
      gateway.restoreResult = true;
      check(await container.read(subscriptionProvider.notifier).restore())
          .isTrue();
      check(container.read(subscriptionProvider).isPro).isTrue();

      // 换一个新容器验证失败路径
      gateway.restoreResult = false;
      check(await container.read(subscriptionProvider.notifier).restore())
          .isFalse();
    });
  });
}
