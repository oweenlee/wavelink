import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../data/services/subscription_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/subscription_provider.dart';

/// 苹果审核（Guideline 3.1.2）要求付费墙内提供《使用条款》与《隐私政策》
/// 链接；买断条款文案由 l10n.paywallTerms 承载（一次性购买 + 价格），勿删减。
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

  List<ProductDetails> _products = const [];
  bool _loading = true;
  bool _purchasing = false;
  String? _error;

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
      _loading = false;
      _error = products.isEmpty ? 'offerings_empty' : null;
    });
  }

  Future<void> _purchase(ProductDetails product) async {
    setState(() {
      _purchasing = true;
      _error = null;
    });
    try {
      final ok = await ref.read(subscriptionProvider.notifier).purchase(product);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        // 购买取消/失败：purchase 返回 false，canceled 不弹错由 in_app_purchase 以 false 体现
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
      final ok = await ref.read(subscriptionProvider.notifier).restore();
      if (!mounted) return;
      if (ok) {
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
    final isPro = ref.watch(subscriptionProvider.select((s) => s.isPro));

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
              const SizedBox(height: 24),
              _featureRow(LucideIcons.headphones, l10n.paywallFeatureAutoEq),
              _featureRow(LucideIcons.building2, l10n.paywallFeatureRoomCorrection),
              _featureRow(LucideIcons.badgeCheck, l10n.paywallFeatureBitPerfect),
              const Spacer(),
              if (isPro)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    l10n.paywallPurchased,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                )
              else ...[
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
                    _PurchaseButton(
                      product: product,
                      purchasing: _purchasing,
                      accent: accent,
                      onTap: () => _purchase(product),
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
              if (!isPro && _products.isNotEmpty)
                Text(
                  l10n.paywallTerms(_products.first.price),
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

  Widget _featureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
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

/// 购买按钮：标题取本地化价格（StoreKit 已按地区货币格式化），一次性买断。
class _PurchaseButton extends StatelessWidget {
  final ProductDetails product;
  final bool purchasing;
  final Color accent;
  final VoidCallback onTap;

  const _PurchaseButton({
    required this.product,
    required this.purchasing,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final price = product.price;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: purchasing ? null : onTap,
        child: purchasing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                l10n.paywallBuyButton(price),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
