import 'dart:io';

import 'package:purchases_flutter/purchases_flutter.dart';

import 'log.dart';

/// RevenueCat 权益服务（Pro 功能付费墙）。
///
/// 当前为**非消耗型一次性买断**（IAP non-consumable）：购买一次永久解锁，
/// 权益判定仍走 entitlement（与订阅同构，后续如需切回订阅/换方案无需改代码）。
///
/// 上线前需完成：
/// 1. RevenueCat 控制台创建项目，构建时注入 API Key（经 fastlane 从环境变量注入）：
///    iOS: --dart-define=REVENUECAT_APPLE_KEY=appl_xxx；
///    Android（可选）: --dart-define=REVENUECAT_GOOGLE_KEY=goog_xxx；
/// 2. App Store Connect 创建**非消耗型内购**商品（wavelink_pro，不可变 ID），
///    并在 RevenueCat 关联为 entitlement `pro`。
///
/// 当前平台未配置 Key 时所有接口静默降级为「未购买」，App 其余功能不受影响。
class SubscriptionService {
  SubscriptionService._();

  /// RevenueCat Apple API Key（appl_ 开头）。
  /// 通过 --dart-define=REVENUECAT_APPLE_KEY=appl_xxx 注入，避免明文进仓库。
  /// 未注入（空值）时所有接口静默降级为「未订阅」。
  static const String _appleApiKey =
      String.fromEnvironment('REVENUECAT_APPLE_KEY');

  /// RevenueCat Google API Key（goog_ 开头，可选）。
  /// Android 端接入订阅后由构建注入；未注入时 Android 静默降级为免费版。
  static const String _googleApiKey =
      String.fromEnvironment('REVENUECAT_GOOGLE_KEY');

  /// 按当前平台选择 API Key。
  static String get _platformApiKey =>
      Platform.isAndroid ? _googleApiKey : _appleApiKey;

  /// RevenueCat entitlement 标识：拥有即 Pro。
  static const String proEntitlementId = 'pro';

  /// 买断 Pro 产品标识（App Store Connect 非消耗型内购，ID 创建后不可变）。
  static const String proProductId = 'wavelink_pro';

  static bool _initialized = false;

  static bool get initialized => _initialized;

  /// 初始化 RevenueCat。失败只记日志不抛错（无网/未配置 Key 均可离线用）。
  static Future<void> init() async {
    if (_initialized || kKeyMissing) return;
    try {
      final config = PurchasesConfiguration(_platformApiKey);
      await Purchases.configure(config);
      _initialized = true;
      Log.i('Subscription', 'RevenueCat 初始化完成');
    } catch (e) {
      Log.e('Subscription', 'RevenueCat 初始化失败: $e');
    }
  }

  /// 当前平台的 API Key 是否未注入。
  static bool get kKeyMissing => _platformApiKey.isEmpty;

  /// 当前是否拥有 Pro 权益。未初始化/查询失败一律视为未购买。
  static Future<bool> isPro() async => (await queryPro()) ?? false;

  /// 三态权益查询：`true`/`false` 为明确结论，`null` 表示未初始化或查询
  /// 失败（无法确认）。权益**撤销**类操作（清理 Pro 设置）只应在拿到明确
  /// `false` 时执行，避免一次网络抖动把合法订阅用户的设置清掉。
  static Future<bool?> queryPro() async {
    if (!_initialized) return null;
    try {
      final info = await Purchases.getCustomerInfo();
      return info.entitlements.all[proEntitlementId]?.isActive ?? false;
    } catch (e) {
      Log.e('Subscription', '查询订阅状态失败: $e');
      return null;
    }
  }

  /// 从 CustomerInfo 推导 Pro 是否激活（供权益变更监听复用同一判定）。
  static bool proFromInfo(CustomerInfo info) =>
      info.entitlements.all[proEntitlementId]?.isActive ?? false;

  /// 订阅权益变更监听：续订/过期/退款等都会推送新 CustomerInfo。
  /// SDK 注册时会立即用最近一次缓存的 CustomerInfo 回调一次。
  static void addCustomerInfoListener(CustomerInfoUpdateListener l) =>
      Purchases.addCustomerInfoUpdateListener(l);

  static void removeCustomerInfoListener(CustomerInfoUpdateListener l) =>
      Purchases.removeCustomerInfoUpdateListener(l);

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
