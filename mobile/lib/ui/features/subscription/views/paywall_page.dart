import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../view_models/subscription_provider.dart';
import '../../../../data/services/subscription_service.dart';

/// 付费墙（方案 C：本地播放免费，网络来源 + 高级 DSP 订阅解锁）。
///
/// 设计对齐主流播放器付费墙：
/// - 顶部品牌 + 订阅卖点；
/// - 免费/高级功能对照（三行，够用且不臃肿）；
/// - 月度/年度两档（年度默认推荐，标注「省 40%」）；
/// - 底部订阅按钮 + 恢复购买 + 条款小字。
class PaywallPage extends ConsumerStatefulWidget {
  const PaywallPage({super.key});

  @override
  ConsumerState<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends ConsumerState<PaywallPage> {
  int _selectedIndex = 0; // 默认年度（plans 列表年度在前）

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(subscriptionProvider);
    final plans = status.plans;

    // 已订阅：直接显示已激活状态（购买/恢复成功后回到这里）
    if (status.isSubscribed) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.badgeCheck,
                  size: 56, color: AppTheme.ok),
              const SizedBox(height: 16),
              Text(
                l10n.paywallActive,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                status.activePlan?.title ?? '',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final selected = plans.isEmpty ? null : plans[_selectedIndex];

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 品牌
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    'assets/splash/logo.png',
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.paywallTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.paywallSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 28),

              // 功能对照
              _FeatureRow(
                icon: LucideIcons.check,
                label: l10n.paywallFeatureNas,
              ),
              _FeatureRow(
                icon: LucideIcons.check,
                label: l10n.paywallFeatureWebdav,
              ),
              _FeatureRow(
                icon: LucideIcons.check,
                label: l10n.paywallFeatureServer,
              ),
              _FeatureRow(
                icon: LucideIcons.check,
                label: l10n.paywallFeatureDsp,
              ),
              const SizedBox(height: 24),

              // 套餐选择（加载中占位）
              if (plans.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                )
              else ...[
                for (var i = 0; i < plans.length; i++)
                  _PlanTile(
                    plan: plans[i],
                    selected: i == _selectedIndex,
                    onTap: () => setState(() => _selectedIndex = i),
                  ),
                const SizedBox(height: 24),
              ],

              // 购买按钮
              if (selected != null)
                _SubscribeButton(
                  plan: selected,
                  loading: status.isLoading,
                  onPressed: () async {
                    final outcome = await ref
                        .read(subscriptionProvider.notifier)
                        .purchase(selected);
                    if (!mounted) return;
                    if (outcome == PurchaseOutcome.failed) {
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.paywallPurchaseFailed),
                          backgroundColor: AppTheme.surfaceHigh,
                        ),
                      );
                    }
                    // 成功：status.isSubscribed 变 true，页面自动切到已激活；
                    // 用户取消：静默，留在付费墙。
                  },
                ),
              const SizedBox(height: 12),

              // 恢复购买
              TextButton(
                onPressed: status.isLoading
                    ? null
                    : () async {
                        final ok = await ref
                            .read(subscriptionProvider.notifier)
                            .restore();
                        if (!mounted) return;
                        if (!ok) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.paywallRestoreFailed),
                              backgroundColor: AppTheme.surfaceHigh,
                            ),
                          );
                        }
                      },
                child: Text(
                  l10n.paywallRestore,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),

              // 条款小字
              Text(
                l10n.paywallTerms,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.6,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FeatureRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.ok),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  final SubscriptionPlan plan;
  final bool selected;
  final VoidCallback onTap;

  const _PlanTile({
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppTheme.accentFallback : AppTheme.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        plan.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      if (plan.isAnnual) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accentFallback.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'BEST VALUE',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: AppTheme.accentFallback,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    plan.priceText,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? LucideIcons.circleCheck
                  : LucideIcons.circle,
              size: 22,
              color: selected ? AppTheme.accentFallback : AppTheme.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscribeButton extends StatelessWidget {
  final SubscriptionPlan plan;
  final bool loading;
  final VoidCallback onPressed;

  const _SubscribeButton({
    required this.plan,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 50,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.accentFallback,
          disabledBackgroundColor: AppTheme.textDisabled,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.textPrimary,
                ),
              )
            : Text(
                l10n.paywallSubscribe(plan.priceText),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
      ),
    );
  }
}
