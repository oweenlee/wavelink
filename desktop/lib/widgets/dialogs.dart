import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../models/track.dart';
import '../services/player_controller.dart';
import '../services/player_providers.dart';

// 单色板别名来自 core/theme.dart（与 ThemeData 同源）；别名仅为缩短引用。
const _surface = kSurface;
const _onSurface = kOnSurface;
const _onSurfaceVariant = kOnSurfaceVariant;
const _border = kBorder;

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
        title: Text(title, style: const TextStyle(color: _onSurface)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: _onSurface),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: _onSurfaceVariant),
            enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _border),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _onSurfaceVariant),
            ),
          ),
          onSubmitted: (value) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.btnCancel,
                style: const TextStyle(color: _onSurfaceVariant)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(l10n.btnOk,
                style: const TextStyle(color: _onSurface)),
          ),
        ],
      ),
    );
  } finally {
    ctrl.dispose();
  }
}

/// 「加入播放列表」对话框：既有列表点选 + 新建播放列表。
/// 列表变化经 [playlistsProvider] 实时刷新。
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  PlayerController player,
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
            ref.watch(playlistsProvider);
            final pls = player.playlists;
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
                          player.playlists.last.id, track.id);
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
