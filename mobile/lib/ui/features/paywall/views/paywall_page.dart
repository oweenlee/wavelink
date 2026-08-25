import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../data/services/subscription_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/subscription_provider.dart';

/// 苹果审核（Guideline 3.1.2）要求付费墙内提供《使用条款》与《隐私政策》
/// 链接；试用条款文案由 l10n.paywallTerms 承载，勿删减。
class PaywallPage extends ConsumerStatefulWidget {
  const PaywallPage({super.key});

  @override
  ConsumerState<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends ConsumerState<PaywallPage> {
  /// EULA 用苹果标准协议链接即可满足审核；隐私政策部署在项目 website/。
  /// TODO: 隐私政策 URL 上线前确认最终域名后替换。
  static const _termsUrl =
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';
  static const _privacyUrl =
      'https://oweenlee.github.io/wavelink/privacy-policy/';

  List<Package> _packages = const [];
  bool _loading = true;
  bool _purchasing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOfferings();
  }

  Future<void> _loadOfferings() async {
    final packages = await SubscriptionService.getOfferings();
    if (!mounted) return;
    setState(() {
      _packages = packages;
      _loading = false;
      // 未拉到套餐：未配置商品或离线，展示占位错误
      _error = packages.isEmpty ? 'offerings_empty' : null;
    });
  }

  Future<void> _purchase(Package package) async {
    setState(() {
      _purchasing = true;
      _error = null;
    });
    try {
      final ok = await ref.read(subscriptionProvider.notifier).purchase(package);
      if (!mounted) return;
      if (ok) Navigator.of(context).pop(true);
    } on PlatformException catch (e) {
      // 用户取消购买是正常路径，不弹错误（官方助手解析错误码）
      final cancelled = PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError;
      if (!cancelled && mounted) {
        setState(() => _error = 'purchase_failed');
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
      // 恢复失败不透出原始异常（英文堆栈对用户无意义），统一走本地化文案
      if (mounted) setState(() => _error = 'generic');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);

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
                for (final package in _packages)
                  _PurchaseButton(
                    package: package,
                    purchasing: _purchasing,
                    accent: accent,
                    onTap: () => _purchase(package),
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
              ],
              const SizedBox(height: 8),
              // 苹果审核要求明示到期后价格，用 priceString（StoreKit 已按
              // 地区货币格式化）。注意：当前仅配置单个月度套餐，条款只取
              // 首个套餐的价格；将来加年费等多套餐时需逐套餐展示条款，
              // 否则条款价与按钮价不一致会被审核挑刺。
              if (_packages.isNotEmpty)
                Text(
                  l10n.paywallTerms(_packages.first.storeProduct.priceString),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textTertiary,
                  ),
                ),
              const SizedBox(height: 4),
              // Guideline 3.1.2：付费墙必须可访问使用条款与隐私政策
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

  /// 外链用系统浏览器打开（应用内无 WebView）。失败静默。
  Future<void> _openLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// 套餐购买按钮：标题取本地化价格（StoreKit 已按地区货币格式化），
/// 免费试用套餐追加「先试后买」徽标文案。
class _PurchaseButton extends StatelessWidget {
  final Package package;
  final bool purchasing;
  final Color accent;
  final VoidCallback onTap;

  const _PurchaseButton({
    required this.package,
    required this.purchasing,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final price = package.storeProduct.priceString;
    final hasTrial =
        package.storeProduct.introductoryPrice != null;

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
                hasTrial
                    ? l10n.paywallTrialButton(price)
                    : l10n.paywallSubscribeButton(price),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
