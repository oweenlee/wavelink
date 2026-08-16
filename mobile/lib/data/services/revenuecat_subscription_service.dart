import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart' as rc;
import 'subscription_service.dart';

/// RevenueCat 真实计费实现（方案 C：App Store / Google Play 双平台统一）。
///
/// 使用方式：
/// 1. 在 App Store Connect / Google Play Console 各建订阅商品（月度+年度）；
/// 2. RevenueCat 后台创建对应 products + entitlements，拿到 API Key；
/// 3. 通过 --dart-define=SUBSCRIPTION_BACKEND=revenuecat 启用本实现；
/// 4. API Key 通过 --dart-define=REVENUECAT_PUBLIC_API_KEY=... 注入。
///
/// 设计要点：
/// - 不直接依赖商店 SDK，统一走 RevenueCat（双平台一套代码）；
/// - [statusStream] 监听 Purchases 的 customerInfo 更新（购买/恢复/失效自动同步）；
/// - 方案 C 无免费试用：entitlement 激活即视为已订阅。
class RevenueCatSubscriptionService implements SubscriptionService {
  RevenueCatSubscriptionService({
    required this.publicApiKey,
    this.entitlementId = 'pro',
  });

  final String publicApiKey;

  /// RevenueCat entitlement 标识（后台创建的 entitlement id）。
  final String entitlementId;

  bool _initialized = false;
  bool _subscribed = false;
  SubscriptionPlan? _activePlan;
  DateTime? _expiresAt;
  final _controller = StreamController<SubscriptionStatus>.broadcast();

  /// productIdentifier → plan 映射（fetchPlans 时缓存），
  /// 用于从 entitlement.productIdentifier 反查当前生效套餐。
  final Map<String, SubscriptionPlan> _plansByProductId = {};

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    // App Store 用公钥，Google Play 用公钥（RevenueCat 统一 public SDK key）
    await rc.Purchases.setLogLevel(rc.LogLevel.warn);
    await rc.Purchases.configure(
      rc.PurchasesConfiguration(publicApiKey),
    );
    _initialized = true;

    // 订阅状态变化（购买/恢复/到期/退款）实时同步到 UI
    rc.Purchases.addCustomerInfoUpdateListener((info) {
      _applyCustomerInfo(info);
    });

    final info = await rc.Purchases.getCustomerInfo();
    _applyCustomerInfo(info);
    _emit();
  }

  void _applyCustomerInfo(rc.CustomerInfo info) {
    final entitlement = info.entitlements.active[entitlementId];
    _subscribed = entitlement != null;
    final expires = entitlement?.expirationDate;
    _expiresAt = expires == null ? null : DateTime.tryParse(expires);
    // 反查当前生效套餐（重启后 activePlan 为空时，凭 entitlement 恢复套餐名展示）
    final productId = entitlement?.productIdentifier;
    if (_subscribed && productId != null) {
      _activePlan = _plansByProductId[productId] ?? _activePlan;
    }
    _emit();
  }

  void _emit() {
    if (_controller.hasListener) {
      _controller.add(_status());
    }
  }

  SubscriptionStatus _status() => SubscriptionStatus(
        isSubscribed: _subscribed,
        activePlan: _activePlan,
        expiresAt: _expiresAt,
      );

  @override
  Future<List<SubscriptionPlan>> fetchPlans() async {
    final offerings = await rc.Purchases.getOfferings();
    final current = offerings.current;
    if (current == null) return const [];

    final plans = <SubscriptionPlan>[];
    for (final pkg in current.availablePackages) {
      final storeProduct = pkg.storeProduct;
      final period = storeProduct.subscriptionPeriod;
      // RevenueCat 的 period 是 ISO8601 时长（如 P1M / P1Y / P12M）。
      // 用解析而非 contains('Y')：P12M 等值于一年，避免误判为月度。
      final isAnnual = _isAnnualPeriod(period);
      final plan = SubscriptionPlan(
        productId: pkg.identifier,
        title: pkg.storeProduct.title,
        priceText: storeProduct.priceString,
        periodDays: isAnnual ? 365 : 30,
        // 免费试用（introductory price = 0）的天数；折扣价不算试用
        trialDays: _introTrialDays(storeProduct.introductoryPrice),
        isAnnual: isAnnual,
      );
      plans.add(plan);
      // 缓存 productIdentifier → plan，供 _applyCustomerInfo 反查套餐名
      _plansByProductId[storeProduct.identifier] = plan;
    }
    // 年度优先（付费墙默认推荐）
    plans.sort((a, b) {
      if (a.isAnnual != b.isAnnual) return a.isAnnual ? -1 : 1;
      return a.periodDays.compareTo(b.periodDays);
    });
    return plans;
  }

  /// 从 IntroductoryPrice 提取免费试用天数。
  /// 仅当 introductory 价格为 0（真免费试用）时返回天数，否则返回 0。
  static int _introTrialDays(rc.IntroductoryPrice? intro) {
    if (intro == null || intro.price != 0) return 0;
    return _iso8601Days(intro.period);
  }

  /// 解析 ISO8601 时长字符串为天数（P1Y / P2W / P14D 等）。
  /// 解析失败或空串返回 0。
  static int _iso8601Days(String? period) {
    if (period == null || period.isEmpty) return 0;
    final matches = RegExp(r'(\d+)([YMWD])').allMatches(period);
    var totalDays = 0;
    for (final m in matches) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      final unit = m.group(2)!;
      switch (unit) {
        case 'Y':
          totalDays += n * 365;
        case 'M':
          totalDays += n * 30;
        case 'W':
          totalDays += n * 7;
        case 'D':
          totalDays += n;
      }
    }
    return totalDays;
  }

  /// 判断 ISO8601 订阅周期是否 ≥1 年（处理 P1Y、P12M 等）。
  static bool _isAnnualPeriod(String? period) {
    return _iso8601Days(period) >= 330;
  }

  @override
  Future<PurchaseOutcome> purchase(SubscriptionPlan plan) async {
    try {
      // 方案 C：无试用，直接购买套餐
      final result = await rc.Purchases.purchase(
        rc.PurchaseParams.package(await _packageById(plan.productId)),
      );
      // 购买成功后 customerInfo 已更新，统一走 _applyCustomerInfo 解析
      _applyCustomerInfo(result.customerInfo);
      if (_subscribed) _activePlan = plan;
      _emit();
      return _subscribed ? PurchaseOutcome.success : PurchaseOutcome.failed;
    } on PlatformException catch (e) {
      // 用户主动取消购买：静默，非错误
      if (rc.PurchasesErrorHelper.getErrorCode(e) ==
          rc.PurchasesErrorCode.purchaseCancelledError) {
        return PurchaseOutcome.cancelled;
      }
      return PurchaseOutcome.failed;
    } catch (_) {
      // 其他异常：由调用方展示失败提示
      return PurchaseOutcome.failed;
    }
  }

  @override
  Future<bool> restorePurchases() async {
    try {
      final info = await rc.Purchases.restorePurchases();
      _applyCustomerInfo(info);
      return _subscribed;
    } catch (_) {
      return false;
    }
  }

  Future<rc.Package> _packageById(String id) async {
    final offerings = await rc.Purchases.getOfferings();
    final current = offerings.current;
    if (current == null) {
      throw StateError('No current offering configured in RevenueCat');
    }
    return current.availablePackages.firstWhere(
      (p) => p.identifier == id,
      orElse: () => throw StateError('Package $id not found'),
    );
  }

  @override
  Stream<SubscriptionStatus> get statusStream => _controller.stream;
}
