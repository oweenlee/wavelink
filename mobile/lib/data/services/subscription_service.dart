import 'dart:async';

/// 订阅方案（对应商店里的一个订阅商品，如月度/年度）。
class SubscriptionPlan {
  const SubscriptionPlan({
    required this.productId,
    required this.title,
    required this.priceText,
    required this.periodDays,
    this.trialDays = 0,
    this.isAnnual = false,
  });

  /// 商店侧商品 ID（RevenueCat 中即 package store product id）。
  final String productId;

  /// 展示标题，如「月度会员」「年度会员」。
  final String title;

  /// 展示价格文案，如「¥12/月」「¥98/年」。
  final String priceText;

  /// 一个计费周期的天数（用于展示「折合每天」等计算）。
  final int periodDays;

  /// 免费试用天数（方案 C 暂不使用，保留字段供未来扩展）。
  final int trialDays;

  /// 是否年度档（付费墙默认推荐年度）。
  final bool isAnnual;
}

/// 订阅状态（以「是否已订阅」为唯一事实源，足够支撑方案 C 的锁定逻辑）。
class SubscriptionStatus {
  const SubscriptionStatus({
    this.isSubscribed = false,
    this.isLoading = false,
    this.error,
    this.activePlan,
    this.expiresAt,
  });

  /// 是否已订阅（含已激活的年/月度会员）。
  final bool isSubscribed;

  /// 初始化/购买请求进行中。
  final bool isLoading;

  /// 最近一次操作失败原因（展示给用户）。
  final String? error;

  /// 当前生效的套餐（未订阅为 null）。
  final SubscriptionPlan? activePlan;

  /// 订阅到期时间（可空）。
  final DateTime? expiresAt;

  SubscriptionStatus copyWith({
    bool? isSubscribed,
    bool? isLoading,
    String? error,
    bool clearError = false,
    SubscriptionPlan? activePlan,
    DateTime? expiresAt,
  }) {
    return SubscriptionStatus(
      isSubscribed: isSubscribed ?? this.isSubscribed,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      activePlan: activePlan ?? this.activePlan,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}

/// 订阅服务抽象。
///
/// 两种实现：
/// - [MockSubscriptionService]：本地开发/测试用，无商店账号即可跑通
///   购买→解锁→恢复全链路（默认，通过 --dart-define=SUBSCRIPTION_BACKEND=mock）；
/// - [RevenueCatSubscriptionService]：真实计费，App Store / Google Play
///   双平台统一走 RevenueCat（--dart-define=SUBSCRIPTION_BACKEND=revenuecat）。
abstract class SubscriptionService {
  /// 初始化（拉起配置、恢复上次订阅状态）。幂等，可重复调用。
  Future<void> initialize();

  /// 拉取可购买的套餐列表。
  Future<List<SubscriptionPlan>> fetchPlans();

  /// 发起订阅购买（方案 C 无试用期，直接激活）。
  Future<bool> purchase(SubscriptionPlan plan);

  /// 恢复购买（换设备/重装后找回订阅）。
  Future<bool> restorePurchases();

  /// 订阅状态变化流（购买成功、恢复、失效都会推送）。
  Stream<SubscriptionStatus> get statusStream;
}
