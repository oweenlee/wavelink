import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/player_notifier.dart';
import '../services/player_providers.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;

/// 单行文本命名对话框（新建播放列表等）。对齐 mobile 端「一个用途一个
/// 统一入口」的组件思路：此前 home.dart 内 `_askName` 与 `_askNewPlaylist`
/// 两份近似实现，合并为此处单一实现。
Future<String?> askNameDialog(
  BuildContext context, {
  required String title,
  required String hint,
}) async {
  final l10n = AppLocalizations.of(context);
  final ctrl = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        // 标题与其他对话框统一品牌字体
        title: Text(title,
            style: const TextStyle(
                fontFamily: 'SpaceGrotesk',
                color: _onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: _onSurface, fontSize: 13.5),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: _onSurfaceVariant),
            isDense: true,
            filled: true,
            fillColor: AppTheme.s3,
            // 与网络音源对话框同高（≈44px）
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppTheme.highlightStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: AppTheme.textTertiary, width: 1.4),
            ),
          ),
          onSubmitted: (value) {
            if (ctrl.text.trim().isNotEmpty) Navigator.pop(ctx, ctrl.text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.btnCancel,
                style: const TextStyle(color: _onSurfaceVariant)),
          ),
          // 空名禁用：此前可点确定但调用方静默忽略，用户无反馈
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: ctrl,
            builder: (c, v, _) => FilledButton(
              onPressed:
                  v.text.trim().isEmpty ? null : () => Navigator.pop(ctx, ctrl.text),
              style: FilledButton.styleFrom(
                backgroundColor: _onSurface,
                disabledBackgroundColor: AppTheme.s3,
                disabledForegroundColor: AppTheme.textTertiary,
                foregroundColor: _surface,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(l10n.btnOk),
            ),
          ),
        ],
      ),
    );
  } finally {
    ctrl.dispose();
  }
}

/// 「加入播放列表」对话框：既有列表点选 + 新建播放列表。
/// 列表变化经 playerProvider 的 playlists select 实时刷新。
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  PlayerNotifier player,
  Track track,
) async {
  final l10n = AppLocalizations.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: _surface,
      title: Text(l10n.dlgAddToPlaylist,
          style: const TextStyle(color: _onSurface)),
      content: SizedBox(
        width: 300,
        child: Consumer(
          builder: (context, ref, _) {
            // 订阅播放列表变化，使对话框内列表实时刷新
            final pls = ref.watch(playerProvider.select((s) => s.playlists));
            return ListView(
              shrinkWrap: true,
              children: [
                ...pls.map(
                  (pl) => ListTile(
                    title: Text(pl.name,
                        style: const TextStyle(color: _onSurface)),
                    subtitle: Text(l10n.trackCount(pl.trackIds.length),
                        style:
                            const TextStyle(color: _onSurfaceVariant)),
                    onTap: () {
                      player.addToPlaylist(pl.id, track.id);
                      Navigator.pop(ctx);
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.plus,
                      color: AppTheme.textTertiary),
                  title: Text(l10n.newPlaylist,
                      style: const TextStyle(color: _onSurface)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final name = await askNameDialog(
                      context,
                      title: l10n.dlgNewPlaylistTitle,
                      hint: l10n.playlistNameHint,
                    );
                    if (name != null && name.trim().isNotEmpty) {
                      await player.createPlaylist(name.trim());
                      await player.addToPlaylist(
                          ref.read(playerProvider).playlists.last.id, track.id);
                    }
                  },
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
