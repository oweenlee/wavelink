import 'package:checks/checks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/ui/features/paywall/view_models/subscription_provider.dart';

// ── Fake ──────────────────────────────────────────────────────────────────

class FakeGateway implements SubscriptionGateway {
  bool initCalled = false;
  int initCount = 0;

  @override
  bool configured = true;

  @override
  bool keyMissing = false;

  bool? queryProResult = false;

  bool purchaseResult = true;
  Object? purchaseError;
  ProductDetails? purchased;

  bool restoreResult = true;

  final List<void Function(bool)> listeners = [];

  @override
  Future<void> init() async {
    initCalled = true;
    initCount++;
  }

  @override
  Future<bool?> queryPro() async => queryProResult;

  @override
  Future<bool> purchase(ProductDetails product) async {
    purchased = product;
    final err = purchaseError;
    if (err != null) throw err;
    return purchaseResult;
  }

  @override
  Future<bool> restore() async => restoreResult;

  @override
  void addCustomerInfoListener(void Function(bool) listener) {
    listeners.add(listener);
  }

  @override
  void removeCustomerInfoListener(void Function(bool) listener) {
    listeners.remove(listener);
  }

  void emit(bool isPro) {
    for (final l in List.of(listeners)) {
      l(isPro);
    }
  }
}

ProductDetails _product() => ProductDetails(
      id: 'wavelink_pro',
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

  Future<SubscriptionState> refresh() async {
    await container.read(subscriptionProvider.notifier).refresh();
    return container.read(subscriptionProvider);
  }

  group('refresh 状态流转', () {
    test('已购买：isPro=true，记录曾激活标记', () async {
      gateway.queryProResult = true;
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.ready).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
      check(revocations).equals(0);
    });

    test('新用户未购买：锁定但不剥夺任何设置', () async {
      gateway.queryProResult = false;
      final s = await refresh();
      check(s.isPro).isFalse();
      check(s.ready).isTrue();
      check(revocations).equals(0);
    });

    test('查询未知（弱网）：乐观恢复最后已知状态，不剥夺（即使有标记）', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.queryProResult = null;
      final s = await refresh();
      check(s.isPro).isTrue();
      check(s.ready).isTrue();
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

    test('明确未激活且曾激活（退款/撤销）：剥夺 Pro 设置并清标记', () async {
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

    test('configure 失败：同样静默降级不剥夺', () async {
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
    test('refresh 后注册监听；运行期撤销即时剥夺', () async {
      gateway.queryProResult = true;
      await refresh();
      check(gateway.listeners).length.equals(1);

      gateway.emit(false);
      check(container.read(subscriptionProvider).isPro).isFalse();
      check(revocations).equals(1);
      check(PreferencesService.instance.proEverActive).isFalse();
    });

    test('重复回调保持幂等：不重复剥夺', () async {
      await PreferencesService.instance.setProEverActive(true);
      gateway.queryProResult = true;
      await refresh();

      gateway.emit(false);
      gateway.emit(false);
      check(revocations).equals(1);
    });

    test('权益被撤销后重新购买恢复 Pro', () async {
      gateway.queryProResult = true;
      await refresh();
      gateway.emit(false);
      gateway.emit(true);
      check(container.read(subscriptionProvider).isPro).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('refresh 幂等：并发调用共享同一 Future（init 只跑一次）', () async {
      gateway.queryProResult = false;
      final f1 = container.read(subscriptionProvider.notifier).refresh();
      final f2 = container.read(subscriptionProvider.notifier).refresh();
      await Future.wait([f1, f2]);
      check(gateway.initCount).equals(1);
      check(container.read(subscriptionProvider).ready).isTrue();
    });

    test('ensureReady：未就绪时等待 refresh 完成，就绪后直接返回', () async {
      gateway.queryProResult = true;
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
          .purchase(_product());
      check(ok).isTrue();
      check(gateway.purchased).isNotNull();
      check(container.read(subscriptionProvider).isPro).isTrue();
      check(PreferencesService.instance.proEverActive).isTrue();
    });

    test('购买返回 false（权益未授予）：状态不变', () async {
      gateway.purchaseResult = false;
      final ok = await container
          .read(subscriptionProvider.notifier)
          .purchase(_product());
      check(ok).isFalse();
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

    test('恢复成功：置位；恢复失败：状态不变', () async {
      gateway.restoreResult = true;
      check(await container.read(subscriptionProvider.notifier).restore())
          .isTrue();
      check(container.read(subscriptionProvider).isPro).isTrue();

      gateway.restoreResult = false;
      check(await container.read(subscriptionProvider.notifier).restore())
          .isFalse();
    });
  });
}
