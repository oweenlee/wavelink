import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import 'cover_art.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;

/// 详情页头部：返回 + 封面 + 标题/副标题 + 可选操作（如播放整张）。
class DetailHeader extends StatelessWidget {
  final String? coverUrl;
  final String seed;
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final Widget? action;
  const DetailHeader({
    super.key,
    required this.coverUrl,
    required this.seed,
    required this.title,
    required this.subtitle,
    required this.onBack,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: const Icon(LucideIcons.arrowLeft,
                size: 20, color: AppTheme.textTertiary),
            tooltip: AppLocalizations.of(context).detailBack,
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          CoverArt(seed: seed, coverUrl: coverUrl, size: 120, rounded: true),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: WlText.display(fontSize: 22)),
                const SizedBox(height: 6),
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: _onSurfaceVariant, fontSize: 13.5)),
                if (action != null) ...[
                  const SizedBox(height: 12),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页小节标题。
Widget sectionTitle(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(label,
          style: const TextStyle(
              color: _onSurface, fontSize: 14, fontWeight: FontWeight.w600)),
    );

/// 详情页空态（艺术家/专辑在曲库变更后失效时）。
Widget detailEmpty(AppLocalizations l10n) => Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.searchX,
              size: 44, color: AppTheme.textTertiary),
          const SizedBox(height: 14),
          Text(l10n.noMatch,
              style: const TextStyle(color: _onSurfaceVariant)),
        ],
      ),
    );
