import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'log.dart';

/// StoreKit 2 / Google Billing 权益服务（Pro 非消耗型买断）。
///
/// 纯端侧无后端：通过 `in_app_purchase` 直连 StoreKit 2（iOS）/ Billing Library（Android），
/// 本地以 `currentEntitlements` / `purchaseStream` 判定 Pro，无需 `REVENUECAT_*` Key。
///
/// 上线前需完成：App Store Connect 创建非消耗型内购 `wavelink_pro`。
class SubscriptionService {
  SubscriptionService._();

  /// 买断 Pro 产品标识（App Store Connect 非消耗型内购，ID 创建后不可变）。
  static const String proProductId = 'wavelink_pro';

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
  static final List<void Function(bool isPro)> _listeners = [];

  /// 当前是否 Pro（内存态，由 purchaseStream 驱动）。
  static bool _isPro = false;
  static bool get isProSync => _isPro;

  /// 购买等待队列：每次 buyNonConsumable 创建一个 Completer，由 _onPurchases 决议
  static final List<Completer<bool>> _purchaseCompleters = [];

  /// restore 投递确认：purchaseStream 任一事件到达即置位。
  /// 空批也算确认（Android 无已购时 restore 会投递空列表），
  /// 用于区分「明确无权益」与「结果未确认」——未确认绝不触发剥夺。
  static bool _restoreDelivered = false;

  /// 初始化：监听 purchaseStream，查询可用性。
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final available = await _iap.isAvailable();
      if (!available) {
        Log.w('Subscription', 'IAP 不可用（模拟器/未配置）');
        // 仍标记已初始化，避免上层无限重试；queryPro 返回 false
        _initialized = true;
        return;
      }
      _sub = _iap.purchaseStream.listen(
        _onPurchases,
        onDone: () => _sub?.cancel(),
        onError: (e) => Log.e('Subscription', 'purchaseStream 错误: $e'),
      );
      _initialized = true;
      Log.i('Subscription', 'IAP 初始化完成');
      // 权益恢复不在此处做：由 provider refresh → queryPro 统一负责，
      // 避免冷启动双重 restore 造成重复流投递与竞态。
    } catch (e) {
      Log.e('Subscription', 'IAP 初始化失败: $e');
      _initialized = true;
    }
  }

  static void _onPurchases(List<PurchaseDetails> purchases) {
    // 任一 purchaseStream 事件到达即视为 restore 投递确认
    _restoreDelivered = true;
    // 本次回调中 wavelink_pro 是否有有效购买
    var found = false;
    var hasErrorOrCancel = false;

    for (final p in purchases) {
      if (p.productID != proProductId) continue;
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        found = true;
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

    final containsPro = purchases.any((p) => p.productID == proProductId);
    bool? newValue;
    if (found) {
      newValue = true;
    } else if (containsPro && hasErrorOrCancel) {
      // 本次购买明确失败/取消：不改 _isPro（保持原值），仅决议购买等待队列
    } else if (containsPro && !found) {
      newValue = false;
    } else if (purchases.isEmpty && _isPro) {
      // restore 重放为空（无已购非消耗型），视为权益已撤销
      newValue = false;
    } else if (!found && _isPro && !containsPro && purchases.isNotEmpty) {
      // 单 SKU 场景：流中无 wavelink_pro 且当前为 Pro，可能为退款后重放
      // 保守不自动清，交由 queryPro/restore 的显式轮询判定
    }

    if (newValue != null && newValue != _isPro) {
      _isPro = newValue;
      for (final l in List.of(_listeners)) {
        try {
          l(_isPro);
        } catch (_) {}
      }
    }

    // 决议购买等待队列
    if (found) {
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
  static Future<bool> isPro() async => (await queryPro()) ?? false;

  /// 三态权益查询：`true`/`false` 为明确结论，`null` 表示未初始化或
  /// 恢复结果未确认（弱网/系统延迟，不剥夺）。
  static Future<bool?> queryPro() async {
    if (!_initialized) return null;
    try {
      if (_isPro) return true;
      // 恢复购买并等待 purchaseStream 投递确认；只有投递确认后才能定论
      // （Android 无已购时 restore 也会投递空批，空批即明确否定）。
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
      return _isPro;
    } catch (e) {
      Log.e('Subscription', '查询订阅状态失败: $e');
      return null;
    }
  }

  /// 执行一次 restorePurchases 并等待 purchaseStream 投递确认（最长 3s）。
  /// `_isPro` 已置位或收到任一事件均视为确认。
  static Future<bool> _restoreAndWait() async {
    _restoreDelivered = false;
    await _iap.restorePurchases();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_isPro || _restoreDelivered) return true;
    }
    return _restoreDelivered;
  }

  static bool proFromPurchase(bool isPro) => isPro;

  static void addCustomerInfoListener(void Function(bool isPro) l) {
    _listeners.add(l);
  }

  static void removeCustomerInfoListener(void Function(bool isPro) l) {
    _listeners.remove(l);
  }

  /// 拉取可售商品（付费墙展示用）。返回空列表表示商品未配置或网络异常。
  static Future<List<ProductDetails>> getOfferings() async {
    if (!_initialized) return const [];
    try {
      final resp = await _iap.queryProductDetails({proProductId});
      if (resp.error != null) {
        Log.e('Subscription', '拉取商品失败: ${resp.error}');
      }
      if (resp.notFoundIDs.isNotEmpty) {
        Log.w('Subscription', '未找到商品: ${resp.notFoundIDs}');
      }
      _cachedProducts = resp.productDetails;
      return _cachedProducts;
    } catch (e) {
      Log.e('Subscription', '拉取商品异常: $e');
      return const [];
    }
  }

  /// 购买指定商品。成功返回是否成为 Pro；用户取消等由 purchaseStream 决议
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

  /// 恢复购买（付费墙按钮）。返回恢复后是否拥有 Pro。
  /// 原生错误向上抛，由调用方处理。
  static Future<bool> restore() async {
    if (!_initialized) return false;
    var delivered = await _restoreAndWait();
    if (!delivered) delivered = await _restoreAndWait();
    return _isPro;
  }

  /// 供测试重置。
  static void debugReset() {
    _isPro = false;
    _cachedProducts = [];
    _restoreDelivered = false;
  }
}
