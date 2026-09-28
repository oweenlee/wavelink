import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'package:wavelink_mobile/data/services/subscription_service.dart';
import 'package:wavelink_mobile/ui/features/paywall/view_models/pro_gate.dart';
import 'package:wavelink_mobile/ui/features/paywall/view_models/subscription_provider.dart';

import 'helpers/fake_subscription_gateway.dart';

/// 门控探针页：一个按钮触发 [requirePro]，一个 [ProBadge] 用于断言徽标显隐。
/// 这是 6 个门控点（NAS/WebDAV/Subsonic/AutoEQ/房间校正/Bit Perfect）的
/// 统一调用形态，此处以最小页复现。
class _GateProbe extends ConsumerStatefulWidget {
  const _GateProbe();

  @override
  ConsumerState<_GateProbe> createState() => _GateProbeState();
}

class _GateProbeState extends ConsumerState<_GateProbe> {
  var ran = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const ProBadge(),
          if (ran) const Text('action-ran'),
          TextButton(
            onPressed: () =>
                requirePro(context, ref, () => setState(() => ran = true)),
            child: const Text('trigger'),
          ),
        ],
      ),
    );
  }
}

void main() {
  late ProviderContainer container;
  late FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
    gateway = FakeGateway();
    container = ProviderContainer(
      overrides: [
        subscriptionGatewayProvider.overrideWithValue(gateway),
        proRevocationHandlerProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(container.dispose);
  });

  /// 挂载探针页与 /paywall 路由（付费墙以文本占位）。
  Future<void> pumpProbe(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const _GateProbe()),
              GoRoute(
                path: '/paywall',
                builder: (_, _) => const Scaffold(body: Text('paywall-page')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 点击 trigger 并等待 requirePro 内部的 ensureReady 异步落地。
  Future<void> tapTrigger(WidgetTester tester) async {
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
  }

  group('requirePro 门控', () {
    testWidgets('已购买：放行 action，且不跳付费墙', (tester) async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.lifetime);
      await pumpProbe(tester);
      await tapTrigger(tester);

      expect(find.text('action-ran'), findsOneWidget);
      expect(find.text('paywall-page'), findsNothing);
    });

    testWidgets('未购买：不执行 action，改道付费墙', (tester) async {
      gateway.queryProResult = const ProEntitlement();
      await pumpProbe(tester);
      await tapTrigger(tester);

      expect(find.text('action-ran'), findsNothing);
      expect(find.text('paywall-page'), findsOneWidget);
    });

    testWidgets('弱网未知且从未激活：等完 ensureReady 仍改道付费墙', (tester) async {
      gateway.queryProResult = null;
      await pumpProbe(tester);
      await tapTrigger(tester);

      // 关键回归点：未就绪窗口内不得放行（否则未购用户可配置并持久化
      // Pro 功能，形成永久白嫖）；refresh 确实被等待过。
      expect(gateway.initCalled, isTrue);
      expect(find.text('action-ran'), findsNothing);
      expect(find.text('paywall-page'), findsOneWidget);
    });

    testWidgets('弱网未知但曾激活订阅：乐观恢复档位并放行', (tester) async {
      await PreferencesService.instance.setProEverActive(true);
      await PreferencesService.instance.setProLastPlanName(ProPlan.yearly.name);
      gateway.queryProResult = null;
      await pumpProbe(tester);
      await tapTrigger(tester);

      expect(find.text('action-ran'), findsOneWidget);
      expect(find.text('paywall-page'), findsNothing);
    });

    testWidgets('订阅到期后再次点击：回到付费墙', (tester) async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.yearly);
      await pumpProbe(tester);
      await tapTrigger(tester);
      expect(find.text('action-ran'), findsOneWidget);

      // 模拟 StoreKit 推送过期
      gateway.emit(ProPlan.none);
      await tester.pumpAndSettle();
      await tapTrigger(tester);

      expect(find.text('paywall-page'), findsOneWidget);
    });
  });

  group('PRO 徽标', () {
    testWidgets('权益查询完成且未购买：显示 PRO', (tester) async {
      gateway.queryProResult = const ProEntitlement();
      await container.read(subscriptionProvider.notifier).refresh();
      await pumpProbe(tester);

      expect(find.text('PRO'), findsOneWidget);
    });

    testWidgets('已购买：不显示 PRO', (tester) async {
      gateway.queryProResult = const ProEntitlement(plan: ProPlan.yearly);
      await container.read(subscriptionProvider.notifier).refresh();
      await pumpProbe(tester);

      expect(find.text('PRO'), findsNothing);
    });

    testWidgets('权益尚未就绪：不显示 PRO（避免启动瞬间闪徽标）', (tester) async {
      // 不触发 refresh：ready 仍为 false
      await pumpProbe(tester);

      expect(find.text('PRO'), findsNothing);
    });
  });
}
