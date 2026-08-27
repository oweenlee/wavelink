import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../../data/services/log.dart';
import '../../../../data/services/subscription_service.dart';
import '../../../core/providers/repositories.dart';
import '../../playback/view_models/playback_controller.dart';
import '../../settings/view_models/dsp_provider.dart';

/// 订阅状态（同步 Notifier：启动时异步查询一次写入，购买/恢复/权益变更
/// 后手动刷新；门控用 `ready && !isPro`，未就绪前放行避免启动闪付费墙）。
class SubscriptionState {
  /// 是否拥有 Pro 权益。
  final bool isPro;

  /// 首次查询是否完成（完成前门控行为保持放行，避免启动闪付费墙）。
  final bool ready;

  const SubscriptionState({this.isPro = false, this.ready = false});

  SubscriptionState copyWith({bool? isPro, bool? ready}) =>
      SubscriptionState(isPro: isPro ?? this.isPro, ready: ready ?? this.ready);
}

/// 订阅能力网关（抽象出来便于单测替换）。生产实现委托
/// [SubscriptionService]（RevenueCat）；测试覆写
/// [subscriptionGatewayProvider] 即可。
abstract interface class SubscriptionGateway {
  /// 初始化 SDK（幂等，失败不抛错）。
  Future<void> init();

  /// SDK 是否已配置成功。
  bool get configured;

  /// 平台 API Key 是否未注入（未注入时静默降级为免费版）。
  bool get keyMissing;

  /// 权益三态查询：`true`/`false` 为明确结论，`null` 表示查询失败/未知。
  Future<bool?> queryPro();

  /// 购买。返回是否成为 Pro；原生错误（PlatformException）向上抛，
  /// 由调用方区分用户取消。
  Future<bool> purchase(Package package);

  /// 恢复购买。返回是否恢复出 Pro；错误向上抛。
  Future<bool> restore();

  /// 权益变更监听（续订/过期/退款推送）；注册时会以最近缓存回调一次。
  void addCustomerInfoListener(CustomerInfoUpdateListener listener);

  void removeCustomerInfoListener(CustomerInfoUpdateListener listener);
}

/// 生产网关：委托 RevenueCat。
class RevenueCatGateway implements SubscriptionGateway {
  @override
  Future<void> init() => SubscriptionService.init();

  @override
  bool get configured => SubscriptionService.initialized;

  @override
  bool get keyMissing => SubscriptionService.kKeyMissing;

  @override
  Future<bool?> queryPro() => SubscriptionService.queryPro();

  @override
  Future<bool> purchase(Package package) => SubscriptionService.purchase(package);

  @override
  Future<bool> restore() => SubscriptionService.restore();

  @override
  void addCustomerInfoListener(CustomerInfoUpdateListener listener) =>
      SubscriptionService.addCustomerInfoListener(listener);

  @override
  void removeCustomerInfoListener(CustomerInfoUpdateListener listener) =>
      SubscriptionService.removeCustomerInfoListener(listener);
}

final subscriptionGatewayProvider = Provider<SubscriptionGateway>(
  (ref) => RevenueCatGateway(),
);

/// 权益失效（过期/退款）后的 Pro 设置剥夺：清掉三个 Pro 专属功能
/// （Bit Perfect / AutoEQ / 房间校正）及其持久化，堵住「订阅期内开启、
/// 到期后永久白嫖」的漏洞。默认读播放编排与 DSP provider 执行；
/// 单测覆写为记录型 Fake。
final proRevocationHandlerProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    try {
      final controller = ref.read(playbackControllerProvider);
      if (controller.bitPerfect) controller.setBitPerfect(false);
      final dsp = ref.read(dspProvider.notifier);
      final dspState = ref.read(dspProvider);
      if (dspState.autoEqModel != null) dsp.setAutoEq(null);
      if (dspState.roomIrPath != null) await dsp.clearRoomCorrection();
    } catch (e) {
      Log.e('Subscription', '剥夺 Pro 设置失败: $e');
    }
  };
});

class SubscriptionNotifier extends Notifier<SubscriptionState> {
  SubscriptionGateway? _gateway;
  CustomerInfoUpdateListener? _listener;

  SubscriptionGateway get _gw {
    final cached = _gateway;
    if (cached != null) return cached;
    final gw = ref.read(subscriptionGatewayProvider);
    _gateway = gw;
    return gw;
  }

  @override
  SubscriptionState build() => const SubscriptionState();

  /// 启动时调用一次：初始化 SDK、注册权益变更监听、查询当前权益。
  /// init 在内部 await，调用方无需先单独初始化（也不阻塞启动路径）。
  Future<void> refresh() async {
    final gw = _gw;
    await gw.init();
    if (gw.keyMissing || !gw.configured) {
      // 未配置（Key 未注入 / 平台不支持 / configure 失败）：静默降级。
      // 这不是明确的权益结论，不剥夺任何设置。
      state = state.copyWith(ready: true);
      return;
    }
    _ensureListener(gw);
    final pro = await gw.queryPro();
    if (pro == null) {
      // 查询失败（网络抖动等）：保持最后已知状态（新用户默认锁定），
      // 只推进 ready；权益变更监听稍后仍会纠正。
      state = state.copyWith(ready: true);
      return;
    }
    _applyEntitlement(pro);
  }

  /// 注册权益变更监听（幂等）：运行期续订/过期/退款即时反映到状态。
  void _ensureListener(SubscriptionGateway gw) {
    if (_listener != null) return;
    _listener = _onCustomerInfo;
    gw.addCustomerInfoListener(_onCustomerInfo);
    ref.onDispose(() {
      final l = _listener;
      if (l != null) gw.removeCustomerInfoListener(l);
      _listener = null;
    });
  }

  void _onCustomerInfo(CustomerInfo info) {
    _applyEntitlement(SubscriptionService.proFromInfo(info));
  }

  /// 权益结果中央处理：
  /// - 激活：置位并持久化「曾激活」标记；
  /// - 明确未激活且曾激活过（过期/退款）：剥夺 Pro 设置并清除标记。
  /// 只在拿到**明确**结论时才写状态，查询失败不触发剥夺。
  void _applyEntitlement(bool active) {
    final prefs = ref.read(preferencesRepositoryProvider);
    if (active) {
      state = state.copyWith(isPro: true, ready: true);
      if (!prefs.proEverActive) unawaited(prefs.setProEverActive(true));
      return;
    }
    state = state.copyWith(isPro: false, ready: true);
    if (prefs.proEverActive) {
      unawaited(prefs.setProEverActive(false));
      Log.w('Subscription', 'Pro 权益失效（过期/退款），已撤销 Pro 设置');
      unawaited(ref.read(proRevocationHandlerProvider)());
    }
  }

  /// 购买。返回是否成功成为 Pro；原生错误向上抛由调用方区分取消。
  Future<bool> purchase(Package package) async {
    final ok = await _gw.purchase(package);
    if (ok) _applyEntitlement(true);
    return ok;
  }

  /// 恢复购买。返回是否恢复出 Pro。
  Future<bool> restore() async {
    final ok = await _gw.restore();
    if (ok) _applyEntitlement(true);
    return ok;
  }
}

final subscriptionProvider =
    NotifierProvider<SubscriptionNotifier, SubscriptionState>(
      SubscriptionNotifier.new,
    );
