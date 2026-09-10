import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'log.dart';

/// Pro 权益档位。枚举顺序即优先级（数值越大越优先）。
enum ProPlan {
  /// 无权益
  none,

  /// 自动续期订阅 · 月度
  monthly,

  /// 自动续期订阅 · 年度
  yearly,

  /// 非消耗型买断
  lifetime,
}

/// 权益快照：档位同时决定「是否 Pro」与「是否订阅制」。
///
/// 订阅制档位（月/年）到期后 StoreKit 不再投递该交易，权益自动回落为
/// [ProPlan.none]；买断档位永久有效。
class ProEntitlement {
  final ProPlan plan;

  const ProEntitlement({this.plan = ProPlan.none});

  bool get isPro => plan != ProPlan.none;

  /// 订阅制：到期会失效，付费墙需提供「管理订阅」入口。
  bool get isSubscription =>
      plan == ProPlan.monthly || plan == ProPlan.yearly;

  @override
  bool operator ==(Object other) =>
      other is ProEntitlement && other.plan == plan;

  @override
  int get hashCode => plan.hashCode;

  @override
  String toString() => 'ProEntitlement(${plan.name})';
}

/// StoreKit 2 权益服务（自动续期订阅 + 买断，纯端侧无后端）。
///
/// 依赖 `in_app_purchase` 3.3+：iOS/macOS 默认注册
/// `InAppPurchaseStoreKitPlatform`（StoreKit 2），`restorePurchases()` 走
/// `AppStore.sync()`，purchaseStream 只投递**当前仍有效**的交易——过期的
/// 订阅不会出现在流里，因此无需后端即可判定订阅是否续期成功。
///
/// 上线前需在 App Store Connect 完成：
/// - 订阅组 `Pro`：`wavelink_pro_monthly`（月）、`wavelink_pro_yearly`（年）
/// - 非消耗型：`wavelink_pro`（买断，不进订阅组）
class SubscriptionService {
  SubscriptionService._();

  /// 自动续期订阅 · 月度
  static const String proMonthlyId = 'wavelink_pro_monthly';

  /// 自动续期订阅 · 年度
  static const String proYearlyId = 'wavelink_pro_yearly';

  /// 非消耗型买断（沿用首个版本的产品 ID）
  static const String proLifetimeId = 'wavelink_pro';

  /// 全部 Pro 商品 ID。
  static const Set<String> proProductIds = {
    proMonthlyId,
    proYearlyId,
    proLifetimeId,
  };

  /// 付费墙展示顺序：月度 → 年度 → 买断。
  static const List<String> tierOrder = [
    proMonthlyId,
    proYearlyId,
    proLifetimeId,
  ];

  /// 订阅制商品（需在付费墙展示自动续订条款与管理入口）。
  static bool isSubscriptionId(String productId) =>
      productId == proMonthlyId || productId == proYearlyId;

  /// 产品 ID → 档位；未知 ID 一律 [ProPlan.none]。
  static ProPlan planOf(String productId) => switch (productId) {
    proMonthlyId => ProPlan.monthly,
    proYearlyId => ProPlan.yearly,
    proLifetimeId => ProPlan.lifetime,
    _ => ProPlan.none,
  };

  /// 多档并存（如买断后仍留有历史订阅）时取最高优先级。
  static ProPlan _strongest(ProPlan a, ProPlan b) => a.index >= b.index ? a : b;

  static bool _initialized = false;
  static bool get initialized => _initialized;

  /// in_app_purchase 3.x 无需 API Key，始终可用；保留该 getter 仅为兼容旧 provider 的 keyMissing 分支。
  static bool get kKeyMissing => false;

  static final InAppPurchase _iap = InAppPurchase.instance;
  static StreamSubscription<List<PurchaseDetails>>? _sub;

  /// 缓存的商品详情（付费墙展示用）。
  static List<ProductDetails> _cachedProducts = [];
  static List<ProductDetails> get cachedProducts => _cachedProducts;

  /// 权益回调（provider 监听）。
  static final List<void Function(ProEntitlement)> _listeners = [];

  /// 当前权益（内存态，由 purchaseStream 驱动）。
  static ProEntitlement _entitlement = const ProEntitlement();
  static ProEntitlement get entitlementSync => _entitlement;

  /// 兼容旧调用：是否拥有 Pro。
  static bool get isProSync => _entitlement.isPro;

  /// 购买等待队列：每次购买创建一个 Completer，由 _onPurchases 决议
  static final List<Completer<bool>> _purchaseCompleters = [];

  /// restore 投递确认：purchaseStream 任一事件到达即置位。
  /// 空批也算确认（无有效权益时 sync 会投递空列表），
  /// 用于区分「明确无权益」与「结果未确认」——未确认绝不触发剥夺。
  static bool _restoreDelivered = false;

  /// 初始化：监听 purchaseStream，查询可用性。
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final available = await _iap.isAvailable();
      if (!available) {
        Log.w('Subscription', 'IAP 不可用（模拟器/未配置）');
        // 仍标记已初始化，避免上层无限重试；queryPro 返回 null
        _initialized = true;
        return;
      }
      _sub = _iap.purchaseStream.listen(
        _onPurchases,
        onDone: () => _sub?.cancel(),
        onError: (e) => Log.e('Subscription', 'purchaseStream 错误: $e'),
      );
      _initialized = true;
      Log.i('Subscription', 'IAP 初始化完成（StoreKit 2）');
      // 权益恢复不在此处做：由 provider refresh → queryPro 统一负责，
      // 避免冷启动双重 sync 造成重复流投递与竞态。
    } catch (e) {
      Log.e('Subscription', 'IAP 初始化失败: $e');
      _initialized = true;
    }
  }

  static void _onPurchases(List<PurchaseDetails> purchases) {
    // 任一 purchaseStream 事件到达即视为 restore 投递确认
    _restoreDelivered = true;
    // 本次回调中有效 Pro 交易的最高档位
    var foundPlan = ProPlan.none;
    var hasErrorOrCancel = false;

    for (final p in purchases) {
      if (!proProductIds.contains(p.productID)) continue;
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        foundPlan = _strongest(foundPlan, planOf(p.productID));
        if (p.pendingCompletePurchase) {
          unawaited(_iap.completePurchase(p));
        }
      } else if (p.status == PurchaseStatus.error) {
        Log.e('Subscription', '购买错误: ${p.error}');
        hasErrorOrCancel = true;
        if (p.pendingCompletePurchase) {
          unawaited(_iap.completePurchase(p));
        }
      } else if (p.status == PurchaseStatus.canceled) {
        hasErrorOrCancel = true;
        if (p.pendingCompletePurchase) {
          unawaited(_iap.completePurchase(p));
        }
      }
      // pending 忽略
    }

    final containsPro = purchases.any(
      (p) => proProductIds.contains(p.productID),
    );
    ProEntitlement? newValue;
    if (foundPlan != ProPlan.none) {
      newValue = ProEntitlement(plan: foundPlan);
    } else if (containsPro && hasErrorOrCancel) {
      // 本次购买明确失败/取消：不改权益（保持原值），仅决议购买等待队列
    } else if (containsPro && foundPlan == ProPlan.none) {
      newValue = const ProEntitlement();
    } else if (purchases.isEmpty && _entitlement.isPro) {
      // sync 重放为空（订阅已过期/已退款），视为权益已撤销
      newValue = const ProEntitlement();
    } else if (!containsPro && purchases.isNotEmpty && _entitlement.isPro) {
      // 流中无 Pro 交易且当前为 Pro，可能为退款后重放
      // 保守不自动清，交由 queryPro/restore 的显式轮询判定
    }

    if (newValue != null && newValue != _entitlement) {
      _entitlement = newValue;
      for (final l in List.of(_listeners)) {
        try {
          l(_entitlement);
        } catch (_) {}
      }
    }

    // 决议购买等待队列
    if (foundPlan != ProPlan.none) {
      for (final c in List.of(_purchaseCompleters)) {
        if (!c.isCompleted) c.complete(true);
      }
      _purchaseCompleters.clear();
    } else if (hasErrorOrCancel) {
      for (final c in List.of(_purchaseCompleters)) {
        if (!c.isCompleted) c.complete(false);
      }
      _purchaseCompleters.clear();
    }
  }

  /// 当前是否拥有 Pro 权益。未初始化一律视为未购买。
  static Future<bool> isPro() async => (await queryPro())?.isPro ?? false;

  /// 三态权益查询：`null` 表示未初始化或恢复结果未确认
  /// （弱网/系统延迟），此时不剥夺——由上层按最后已知状态处理。
  static Future<ProEntitlement?> queryPro() async {
    if (!_initialized) return null;
    try {
      if (_entitlement.isPro) return _entitlement;
      // sync 一次并等待 purchaseStream 投递确认；只有投递确认后才能定论。
      // StoreKit 2 下过期的订阅不会被投递，因此空批即「无有效权益」。
      var delivered = await _restoreAndWait();
      if (!delivered) {
        // 未确认：重试一次再定论，避免误判「未购买」触发
        // Pro 设置剥夺（清 Bit Perfect/AutoEQ/房间校正，不可逆）。
        delivered = await _restoreAndWait();
      }
      if (!delivered) {
        Log.w('Subscription', '恢复购买结果未确认，返回未知（不剥夺）');
        return null;
      }
      return _entitlement;
    } catch (e) {
      Log.e('Subscription', '查询订阅状态失败: $e');
      return null;
    }
  }

  /// 执行一次 restorePurchases（StoreKit 2 → AppStore.sync）并等待
  /// purchaseStream 投递确认（最长 3s）。已置位或收到任一事件均视为确认。
  static Future<bool> _restoreAndWait() async {
    _restoreDelivered = false;
    await _iap.restorePurchases();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_entitlement.isPro || _restoreDelivered) return true;
    }
    return _restoreDelivered;
  }

  static ProEntitlement proFromPurchase(bool isPro) =>
      ProEntitlement(plan: isPro ? ProPlan.lifetime : ProPlan.none);

  static void addCustomerInfoListener(void Function(ProEntitlement) l) {
    _listeners.add(l);
  }

  static void removeCustomerInfoListener(void Function(ProEntitlement) l) {
    _listeners.remove(l);
  }

  /// 拉取可售商品（付费墙展示用），按 [tierOrder] 排序。
  /// 返回空列表表示商品未配置或网络异常。
  static Future<List<ProductDetails>> getOfferings() async {
    if (!_initialized) return const [];
    try {
      final resp = await _iap.queryProductDetails(proProductIds);
      if (resp.error != null) {
        Log.e('Subscription', '拉取商品失败: ${resp.error}');
      }
      if (resp.notFoundIDs.isNotEmpty) {
        Log.w('Subscription', '未找到商品: ${resp.notFoundIDs}');
      }
      final products = List<ProductDetails>.of(resp.productDetails)..sort((
        a,
        b,
      ) {
        final ia = tierOrder.indexOf(a.id);
        final ib = tierOrder.indexOf(b.id);
        return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
      });
      _cachedProducts = products;
      return _cachedProducts;
    } catch (e) {
      Log.e('Subscription', '拉取商品异常: $e');
      return const [];
    }
  }

  /// 购买指定商品（订阅与买断均走 buyNonConsumable）。
  /// 成功返回是否成为 Pro；用户取消等由 purchaseStream 决议。
  static Future<bool> purchase(ProductDetails product) async {
    if (!_initialized) return false;
    final param = PurchaseParam(productDetails: product);
    final completer = Completer<bool>();
    _purchaseCompleters.add(completer);
    try {
      final ok = await _iap.buyNonConsumable(purchaseParam: param);
      if (!ok) {
        if (!completer.isCompleted) completer.complete(false);
        return false;
      }
      // 等待 purchaseStream 决议，最长 60s（用户可能需 FaceID/密码）
      final result = await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => false,
      );
      return result;
    } finally {
      // 异常路径（billing 不可用等）也清队列，避免 completer 泄漏
      _purchaseCompleters.remove(completer);
    }
  }

  /// 恢复购买（付费墙按钮）。返回恢复后的权益。
  static Future<ProEntitlement> restore() async {
    if (!_initialized) return const ProEntitlement();
    var delivered = await _restoreAndWait();
    if (!delivered) delivered = await _restoreAndWait();
    return _entitlement;
  }

  /// 供测试重置。
  static void debugReset() {
    _entitlement = const ProEntitlement();
    _cachedProducts = [];
    _restoreDelivered = false;
  }
}
