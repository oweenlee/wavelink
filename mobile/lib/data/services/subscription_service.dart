import 'package:purchases_flutter/purchases_flutter.dart';

import 'log.dart';

/// RevenueCat 订阅服务（Pro 功能付费墙）。
///
/// 上线前需完成：
/// 1. RevenueCat 控制台创建项目，构建时注入 API Key：
///    --dart-define=REVENUECAT_APPLE_KEY=appl_xxx；
/// 2. App Store Connect 创建自动续期订阅产品（月订阅 + 1 个月免费试用
///    的引进优惠），并在 RevenueCat 关联为 entitlement `pro`。
///
/// 未配置 Key 时所有接口静默降级为「未订阅」，App 其余功能不受影响。
class SubscriptionService {
  SubscriptionService._();

  /// RevenueCat Apple API Key（appl_ 开头）。
  /// 通过 --dart-define=REVENUECAT_APPLE_KEY=appl_xxx 注入，避免明文进仓库。
  /// 未注入（空值）时所有接口静默降级为「未订阅」。
  static const String _appleApiKey =
      String.fromEnvironment('REVENUECAT_APPLE_KEY');

  /// RevenueCat entitlement 标识：拥有即 Pro。
  static const String proEntitlementId = 'pro';

  /// 订阅产品标识（与 App Store Connect / RevenueCat 配置一致）。
  static const String monthlyProductId = 'wavelink_pro_monthly';

  static bool _initialized = false;

  static bool get initialized => _initialized;

  /// 初始化 RevenueCat。失败只记日志不抛错（无网/未配置 Key 均可离线用）。
  static Future<void> init() async {
    if (_initialized || kKeyMissing) return;
    try {
      final config = PurchasesConfiguration(_appleApiKey);
      await Purchases.configure(config);
      _initialized = true;
      Log.i('Subscription', 'RevenueCat 初始化完成');
    } catch (e) {
      Log.e('Subscription', 'RevenueCat 初始化失败: $e');
    }
  }

  static bool get kKeyMissing => _appleApiKey.isEmpty;

  /// 当前是否拥有 Pro 权益。未初始化/查询失败一律视为未订阅。
  static Future<bool> isPro() async {
    if (!_initialized) return false;
    try {
      final info = await Purchases.getCustomerInfo();
      return info.entitlements.all[proEntitlementId]?.isActive ?? false;
    } catch (e) {
      Log.e('Subscription', '查询订阅状态失败: $e');
      return false;
    }
  }

  /// 拉取可售套餐（付费墙展示用）。返回空列表表示商品未配置或网络异常。
  static Future<List<Package>> getOfferings() async {
    if (!_initialized) return const [];
    try {
      final offerings = await Purchases.getOfferings();
      final current = offerings.current;
      if (current == null) return const [];
      return current.availablePackages;
    } catch (e) {
      Log.e('Subscription', '拉取套餐失败: $e');
      return const [];
    }
  }

  /// 购买指定套餐。成功后刷新权益并返回是否成为 Pro。
  /// 与其余接口一致先做初始化检查，避免原生异常漏到上层。
  static Future<bool> purchase(Package package) async {
    if (!_initialized) return false;
    final result = await Purchases.purchase(
      PurchaseParams.package(package),
    );
    return result.customerInfo.entitlements.all[proEntitlementId]?.isActive ??
        false;
  }

  /// 恢复购买。返回恢复后是否拥有 Pro 权益；失败向上抛，由调用方
  /// 统一展示本地化错误（与 purchase 的抛错约定一致）。
  /// 未初始化时直接返回 false：SDK 未 configure 时调原生方法会
  /// fatal error 崩溃，且该崩溃无法被 Dart catch。
  static Future<bool> restore() async {
    if (!_initialized) return false;
    final info = await Purchases.restorePurchases();
    return info.entitlements.all[proEntitlementId]?.isActive ?? false;
  }
}
