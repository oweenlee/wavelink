import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../data/services/subscription_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/subscription_provider.dart';

/// 苹果审核要求付费墙内提供《使用条款》与《隐私政策》链接；
/// 自动续期订阅还须在提交购买前披露价格、周期与自动续订规则
/// （Review Guidelines 3.1.2(c) + 开发者协议 Schedule 2），文案由
/// l10n.paywallTermsSubscription / paywallTermsLifetime 承载，勿删减。
class PaywallPage extends ConsumerStatefulWidget {
  const PaywallPage({super.key});

  @override
  ConsumerState<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends ConsumerState<PaywallPage> {
  /// EULA 用苹果标准协议链接即可满足审核；隐私政策源文件在仓库根目录
  /// website/privacy-policy/，需合入 main 并由 GitHub Pages 服务。
  /// ⚠️ 阻断项：该 URL 当前 404（源文件只在功能分支，未合入 main），
  /// 上线前必须部署到位，否则审核被拒。
  static const _termsUrl =
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';
  static const _privacyUrl =
      'https://oweenlee.github.io/wavelink/privacy-policy/';

  /// 系统订阅管理页：已订阅用户必须能在 App 内触达（3.1.2）。
  static const _manageSubscriptionsUrl =
      'https://apps.apple.com/account/subscriptions';

  List<ProductDetails> _products = const [];
  String? _selectedId;
  bool _loading = true;
  bool _purchasing = false;
  String? _error;

  ProductDetails? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final p in _products) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadOfferings();
  }

  Future<void> _loadOfferings() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final products = await SubscriptionService.getOfferings();
    if (!mounted) return;
    setState(() {
      _products = products;
      _selectedId = _defaultSelection(products);
      _loading = false;
      _error = products.isEmpty ? 'offerings_empty' : null;
    });
  }

  /// 默认选中年度（最划算），缺失时依次回退到月度、买断。
  String? _defaultSelection(List<ProductDetails> products) {
    for (final id in const [
      SubscriptionService.proYearlyId,
      SubscriptionService.proMonthlyId,
      SubscriptionService.proLifetimeId,
    ]) {
      if (products.any((p) => p.id == id)) return id;
    }
    return products.isEmpty ? null : products.first.id;
  }

  Future<void> _purchase() async {
    final product = _selected;
    if (product == null) return;
    setState(() {
      _purchasing = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(subscriptionProvider.notifier)
          .purchase(product);
      if (!mounted) return;
      if (result.isPro) {
        Navigator.of(context).pop(true);
      } else {
        // 购买取消/失败：purchase 返回空权益，canceled 不弹错由 in_app_purchase 体现
        setState(() => _error = 'generic');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'generic');
    } finally {
      if (mounted) setState(() => _purchasing = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _error = null);
    try {
      final result = await ref.read(subscriptionProvider.notifier).restore();
      if (!mounted) return;
      if (result.isPro) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = 'restore_empty');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'generic');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    final sub = ref.watch(subscriptionProvider);
    final isPro = sub.isPro;
    final selected = _selected;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.close, size: 22),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Icon(LucideIcons.crown, color: accent, size: 44),
              const SizedBox(height: 12),
              Text(
                l10n.paywallTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.paywallSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.paywallFreeNote,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textTertiary,
                ),
              ),
              const SizedBox(height: 20),
              _featureRow(
                LucideIcons.building2,
                l10n.paywallFeatureRoomCorrection,
              ),
              _featureRow(LucideIcons.badgeCheck, l10n.paywallFeatureBitPerfect),
              const Spacer(),
              if (isPro) ...[
                Text(
                  l10n.paywallPurchased,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (sub.isSubscription)
                  TextButton(
                    onPressed: () => _openLink(_manageSubscriptionsUrl),
                    child: Text(
                      l10n.paywallManage,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
              ] else ...[
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      _errorMessage(l10n, _error!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.danger,
                      ),
                    ),
                  ),
                if (_loading)
                  const Center(child: CircularProgressIndicator(strokeWidth: 2))
                else ...[
                  for (final product in _products)
                    _PlanCard(
                      product: product,
                      title: _planTitle(l10n, product.id),
                      badge: product.id == SubscriptionService.proYearlyId
                          ? l10n.paywallPlanYearlyNote
                          : null,
                      selected: product.id == _selectedId,
                      accent: accent,
                      onTap: () => setState(() => _selectedId = product.id),
                    ),
                  const SizedBox(height: 12),
                  _PurchaseButton(
                    label: selected == null
                        ? l10n.paywallRetry
                        : _isSubscriptionId(selected.id)
                        ? l10n.paywallSubscribeButton(selected.price)
                        : l10n.paywallBuyButton(selected.price),
                    purchasing: _purchasing,
                    enabled: selected != null,
                    accent: accent,
                    onTap: _purchase,
                  ),
                  TextButton(
                    onPressed: _restore,
                    child: Text(
                      l10n.paywallRestore,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                  if (_error == 'offerings_empty')
                    TextButton(
                      onPressed: _loadOfferings,
                      child: Text(
                        l10n.paywallRetry,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                ],
              ],
              const SizedBox(height: 8),
              if (!isPro && selected != null)
                Text(
                  _termsText(l10n, selected),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textTertiary,
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => _openLink(_termsUrl),
                    child: Text(
                      l10n.paywallTermsOfUse,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textTertiary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => _openLink(_privacyUrl),
                    child: Text(
                      l10n.paywallPrivacyPolicy,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textTertiary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  bool _isSubscriptionId(String id) => SubscriptionService.isSubscriptionId(id);

  String _planTitle(AppLocalizations l10n, String id) => switch (id) {
    SubscriptionService.proMonthlyId => l10n.paywallPlanMonthly,
    SubscriptionService.proYearlyId => l10n.paywallPlanYearly,
    _ => l10n.paywallPlanLifetime,
  };

  /// 订阅档必须披露「价格 / 周期 / 自动续订 / 取消方式」，买断档披露一次性。
  String _termsText(AppLocalizations l10n, ProductDetails product) {
    if (_isSubscriptionId(product.id)) {
      final period = product.id == SubscriptionService.proYearlyId
          ? l10n.paywallPeriodYear
          : l10n.paywallPeriodMonth;
      return l10n.paywallTermsSubscription(period, product.price);
    }
    return l10n.paywallTermsLifetime(product.price);
  }

  Widget _featureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
            ),
          ),
          Icon(LucideIcons.checkCircle2, color: AppTheme.textTertiary, size: 18),
        ],
      ),
    );
  }

  String _errorMessage(AppLocalizations l10n, String error) {
    switch (error) {
      case 'offerings_empty':
        return l10n.paywallErrorOfferings;
      case 'restore_empty':
        return l10n.paywallErrorRestore;
      default:
        return l10n.paywallErrorGeneric;
    }
  }

  Future<void> _openLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// 档位卡片：可点选，选中态高亮（accent 描边）。
class _PlanCard extends StatelessWidget {
  final ProductDetails product;
  final String title;
  final String? badge;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _PlanCard({
    required this.product,
    required this.title,
    required this.badge,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final border = selected ? accent : AppTheme.textTertiary.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border, width: selected ? 1.6 : 1),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? LucideIcons.circleCheck
                      : LucideIcons.circle,
                  size: 18,
                  color: selected ? accent : AppTheme.textTertiary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(fontSize: 10, color: accent),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  product.price,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 购买按钮：标题取本地化价格（StoreKit 已按地区货币格式化）。
class _PurchaseButton extends StatelessWidget {
  final String label;
  final bool purchasing;
  final bool enabled;
  final Color accent;
  final VoidCallback onTap;

  const _PurchaseButton({
    required this.label,
    required this.purchasing,
    required this.enabled,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: (purchasing || !enabled) ? null : onTap,
      child: purchasing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
