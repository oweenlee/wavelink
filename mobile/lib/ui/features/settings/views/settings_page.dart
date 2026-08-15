import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/sheet_shell.dart';
import '../../../core/widgets/wl_toggle.dart';
import '../../playback/view_models/playback_controller.dart';
import '../../playback/view_models/audio_player_provider.dart';
import '../view_models/dsp_provider.dart';
import '../view_models/locale_provider.dart';
import '../view_models/package_info_provider.dart';

/// 设置页。
///
/// 滚动性能设计（对齐曲库列表手感）：
/// - **真懒加载**：build 只收集轻量 builder 闭包，widget 在 itemBuilder
///   内按可见性构建（旧实现把 21 个 item 在 build 里全量构建后再交给
///   ListView.builder，懒构建被完全绕过，进页第一帧和每次重建都很重）。
/// - **行级重建隔离**：开关/滑块行各自是 ConsumerWidget，只 select 自己的
///   字段——切换任一开关只重建那一行，SettingsPage 自身不 watch 任何
///   响应式源，不再整页重建。
/// - **轻量行容器**：_RowShell 用 Container+BoxDecoration，去掉每行一个
///   Material + Clip.antiAlias（滚动时逐帧裁剪开销显著）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final items = <Widget Function(BuildContext)>[];

    void addSection(String title, List<Widget Function(BuildContext)> rows) {
      items.add((_) => _SectionHeader(title: title));
      for (var i = 0; i < rows.length; i++) {
        final isFirst = i == 0;
        final isLast = i == rows.length - 1;
        final row = rows[i];
        items.add(
          (ctx) => _RowShell(
            isFirst: isFirst,
            isLast: isLast,
            child: row(ctx),
          ),
        );
      }
      items.add((_) => const SizedBox(height: 24));
    }

    addSection(l10n.settingsAudio, [
      (_) => _DspSwitchRow(
        icon: LucideIcons.slidersHorizontal,
        label: l10n.dspPipeline,
        select: (s) => s.dspSettings.enabled,
        toggle: (p) => p.toggleDspEnabled(),
      ),
      (_) => _DspSwitchRow(
        icon: LucideIcons.activity,
        label: l10n.dspCrossfeed,
        select: (s) => s.dspSettings.crossfeed,
        toggle: (p) => p.toggleCrossfeed(),
      ),
      (_) => _DspSwitchRow(
        icon: LucideIcons.arrowRight,
        label: l10n.stereoWidening,
        select: (s) => s.dspSettings.widener,
        toggle: (p) => p.toggleWidener(),
      ),
      (_) => _DspSwitchRow(
        icon: LucideIcons.volume2,
        label: l10n.truePeakLimiter,
        select: (s) => s.dspSettings.limiter,
        toggle: (p) => p.toggleLimiter(),
      ),
      // TPDF 抖动/噪声整形不在移动端暴露：双端输出均为 F32，无整数截断
      // 环节，抖动无量化可去相关（桌面整数输出场景才适用）。
      (_) => const _AutoEqRow(),
      (_) => const _RoomCorrectionRow(),
      (_) => const _ReplayGainRow(),
      (_) => const _BitPerfectRow(),
    ]);

    // 主题项已移除：原来是无 onTap 的装饰行（点了没反应），仅深色主题，
    // 与其伪装成功能项不如不展示。
    addSection(l10n.settingsAppearance, [(_) => const _CoverBlurRow()]);

    addSection(l10n.language, [(_) => const _LanguageItem()]);

    addSection(l10n.settingsAbout, [
      (ctx) => _SettingItem(
        icon: LucideIcons.activity,
        label: l10n.diagnosticEntry,
        onTap: () => ctx.push('/diagnostic'),
      ),
      (_) => _SettingItem(
        icon: LucideIcons.mail,
        label: l10n.contactEmail,
        trailing: l10n.contactEmailValue,
        onTap: () => _copyContactEmail(l10n),
      ),
      (_) => const _VersionRow(),
    ]);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index](context),
    );
  }

  /// 复制联系邮箱到剪贴板并 toast 反馈。
  /// - toast 参数与全局统一（timeInSecForIosWeb，而非 Android 语义的
  ///   toastLength，后者在 iOS 走另一条时长路径）；
  /// - Clipboard.setData 在部分 iOS 版本会因隐私弹窗授权失败抛异常
  ///   （用户拒绝剪贴板权限），必须 catch，否则 toast 不显示且产生
  ///   unhandled exception。
  static Future<void> _copyContactEmail(AppLocalizations l10n) async {
    final email = l10n.contactEmailValue;
    try {
      await Clipboard.setData(ClipboardData(text: email));
    } catch (_) {
      // 剪贴板权限被拒：复制失败静默，不打断用户
      return;
    }
    Fluttertoast.showToast(
      msg: l10n.contactEmailCopied,
      gravity: ToastGravity.BOTTOM,
      timeInSecForIosWeb: 2,
      backgroundColor: AppTheme.surfaceHigh,
      textColor: AppTheme.textPrimary,
      fontSize: 13,
    );
  }
}

// ── 行级 Consumer：每行只 select 自己的字段，切换只重建本行 ──

/// DSP 开关行：watch 对应子开关字段，toggle 走 PlaybackController 门面。
class _DspSwitchRow extends ConsumerWidget {
  final IconData icon;
  final String label;
  final bool Function(DspState) select;
  final void Function(PlaybackController) toggle;

  const _DspSwitchRow({
    required this.icon,
    required this.label,
    required this.select,
    required this.toggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(dspProvider.select(select));
    return _SwitchItem(
      icon: icon,
      label: label,
      value: value,
      onChanged: (_) => toggle(ref.read(playbackControllerProvider)),
    );
  }
}

class _AutoEqRow extends ConsumerWidget {
  const _AutoEqRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final model = ref.watch(dspProvider.select((s) => s.autoEqModel));
    return _SettingItem(
      icon: LucideIcons.headphones,
      label: l10n.autoEq,
      trailing: model ?? l10n.autoEqOff,
      onTap: () => context.push('/autoeq'),
    );
  }
}

class _RoomCorrectionRow extends ConsumerWidget {
  const _RoomCorrectionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final irPath = ref.watch(dspProvider.select((s) => s.roomIrPath));
    return _SettingItem(
      icon: LucideIcons.building2,
      label: l10n.roomCorrection,
      trailing: irPath != null
          ? l10n.roomCorrectionActive
          : l10n.roomCorrectionOff,
      onTap: () => context.push('/room-correction'),
    );
  }
}

class _ReplayGainRow extends ConsumerWidget {
  const _ReplayGainRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(playerProvider.select((s) => s.replayGain));
    return _SwitchItem(
      icon: LucideIcons.sparkles,
      label: l10n.replayGain,
      value: value,
      onChanged: (_) =>
          ref.read(playbackControllerProvider).setReplayGain(!value),
    );
  }
}

class _BitPerfectRow extends ConsumerWidget {
  const _BitPerfectRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final bitPerfect = ref.watch(playerProvider.select((s) => s.bitPerfect));
    // telemetry 播放中 500ms 刷新：副标题实时反映链路状态。
    // 只重建本行（旧实现读非响应式 getter，状态长期 stale）。
    final telemetry = ref.watch(playerProvider.select((s) => s.telemetry));
    final dsp = ref.watch(dspProvider.select((s) => s.dspSettings));
    final replayGain = ref.watch(playerProvider.select((s) => s.replayGain));
    return _SwitchItem(
      icon: LucideIcons.badgeCheck,
      label: l10n.bitPerfect,
      value: bitPerfect,
      onChanged: (_) =>
          ref.read(playbackControllerProvider).setBitPerfect(!bitPerfect),
      subtitle: _bitPerfectStatus(bitPerfect, telemetry, dsp, replayGain),
    );
  }
}

class _CoverBlurRow extends ConsumerWidget {
  const _CoverBlurRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(playerProvider.select((s) => s.coverBlur));
    return _SliderItem(
      icon: LucideIcons.droplets,
      label: l10n.coverBlur,
      value: value,
      onChanged: (v) => ref.read(playbackControllerProvider).setCoverBlur(v),
    );
  }
}

/// 版本号展示：运行时从 PackageInfo 读取（与 pubspec 保持一致），
/// 不再走 arb 文案硬编码（曾写死 v0.1.0 与实际 1.0.0 不符）。
class _VersionRow extends ConsumerWidget {
  const _VersionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final v = ref.watch(packageInfoProvider).value?.version;
    return _SettingItem(
      icon: LucideIcons.info,
      label: l10n.version,
      trailing: (v == null || v.isEmpty) ? '—' : 'v$v',
    );
  }
}

class _LanguageItem extends ConsumerWidget {
  const _LanguageItem();

  static const _options = ['system', 'zh', 'ja', 'en'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final localeMode = ref.watch(localeProvider);

    // 跟随系统项的显示名需要本地化
    String labelFor(String mode, AppLocalizations l) {
      switch (mode) {
        case 'zh':
          return '中文';
        case 'ja':
          return '日本語';
        case 'en':
          return 'English';
        default:
          return l.systemDefault;
      }
    }

    return _SettingItem(
      icon: LucideIcons.globe,
      label: l10n.language,
      trailing: labelFor(localeMode, l10n),
      onTap: () => _showLanguageSheet(context, ref),
    );
  }

  Future<void> _showLanguageSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final localeMode = ref.read(localeProvider);
    final accent = AccentScope.of(context);

    String labelFor(String mode) {
      switch (mode) {
        case 'zh':
          return '中文';
        case 'ja':
          return '日本語';
        case 'en':
          return 'English';
        default:
          return l10n.systemDefault;
      }
    }

    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SheetShell(
        title: l10n.language,
        builder: (scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: _options.map((mode) {
            final selected = localeMode == mode;
            return ListTile(
              leading: Icon(
                selected ? LucideIcons.checkCircle2 : LucideIcons.circle,
                color: selected ? accent : AppTheme.textTertiary,
                size: 20,
              ),
              title: Text(
                labelFor(mode),
                style: TextStyle(
                  fontSize: 15,
                  color: selected ? accent : AppTheme.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              dense: true,
              onTap: () {
                ref.read(localeProvider.notifier).setMode(mode);
                Navigator.of(context).pop();
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// bit-perfect 开关副标题：如实反映「有效」状态（偏好 + 实际链路 + DSP）。
/// 与 PlaybackController.effectiveBitPerfect/dspAffectingSignal 判定一致：
/// ReplayGain 逐首叠加增益缩放，同属信号改动，开启时不算 bit-perfect。
String _bitPerfectStatus(
  bool bitPerfect,
  EngineTelemetry t,
  DspSettings dsp,
  bool replayGain,
) {
  if (!bitPerfect) return '未开启';
  final dspTouching =
      dsp.enabled || dsp.crossfeed || dsp.widener || dsp.limiter;
  final effective =
      t.fileRate > 0 &&
      t.fileRate == t.outputRate &&
      (!Platform.isAndroid || t.outputMode == 1) &&
      !dspTouching &&
      !replayGain;
  if (effective) {
    return Platform.isAndroid
        ? 'Exclusive 直通生效中'
        : 'bit-exact（速率匹配）生效中';
  }
  final reasons = <String>[];
  if (t.fileRate > 0 && t.fileRate != t.outputRate) {
    reasons.add('重采样中');
  }
  if (Platform.isAndroid && t.outputMode == 2) {
    reasons.add('Shared 混音器路径');
  }
  if (dspTouching) {
    reasons.add('DSP 未旁路');
  }
  if (replayGain) {
    reasons.add('ReplayGain 开启');
  }
  if (reasons.isEmpty) reasons.add('等待播放');
  return '未生效：${reasons.join(' / ')}';
}

/// 分组标题（独立 item，便于懒加载）
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}

/// 分组内单行容器：行级圆角 + 分隔线。
/// 首行上圆角、末行下圆角、中间无圆角；非首行顶部画分隔线。
/// 背景用 Container+BoxDecoration：行内无图片/墨水溢出需求，不需要
/// Material + Clip.antiAlias 逐帧裁剪（滚动 paint 成本显著更低）。
class _RowShell extends StatelessWidget {
  final bool isFirst;
  final bool isLast;
  final Widget child;

  const _RowShell({
    required this.isFirst,
    required this.isLast,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: isFirst
              ? BorderSide(color: AppTheme.highlight, width: 0.5)
              : BorderSide.none,
          bottom: isLast
              ? BorderSide(color: AppTheme.highlight, width: 0.5)
              : BorderSide.none,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(isFirst ? 14 : 0),
            bottom: Radius.circular(isLast ? 14 : 0),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isFirst)
              Divider(height: 1, indent: 52, color: AppTheme.highlight),
            child,
          ],
        ),
      ),
    );
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback? onTap;

  const _SettingItem({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // GestureDetector 自带 tap action 语义，但需 MergeSemantics 把
    // icon+label+trailing 聚合成单一可点击节点：VoiceOver/TalkBack 焦点
    // 落在整行而非分离的文本片段，且保留 button role 与 enabled 状态。
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onTap != null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: AppTheme.textSecondary, size: 22),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    // 长文案（如 AutoEQ 型号名）限宽单行截断，避免换行挤压标题
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.45,
                    ),
                    child: Text(
                      trailing!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ] else if (onTap != null) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    LucideIcons.chevronRight,
                    color: AppTheme.textTertiary,
                    size: 20,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  const _SwitchItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        // 整行开关：toggled 状态随切换同步，屏幕阅读器可朗读并操作
        toggled: value,
        enabled: true,
        button: true,
        child: GestureDetector(
          // 整行可点：行内任意位置（含文字/图标）都能切换
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: AppTheme.textSecondary, size: 22),
                const SizedBox(width: 16),
                Expanded(
                  child: subtitle == null
                      ? Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            color: AppTheme.textPrimary,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textTertiary,
                              ),
                            ),
                          ],
                        ),
                ),
                const SizedBox(width: 8),
                WlToggle(
                  value: value,
                  // 与音效面板同一组件，开关视觉全局一致
                  onChanged: () => onChanged(!value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _SliderItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Padding(
      // 垂直 12 与 _SettingItem 对齐：整行高度一致，避免滑块行
      // 因内部上下结构比其它分区行高而显得错位
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 22),
          const SizedBox(width: 16),
          // 长文案限宽（按屏宽 40% 自适应，非写死）：label 只占固有
          // 宽度、不参与 flex，滑块 Expanded 独占剩余。
          // 宽屏上限随屏宽放大避免滑块畸长；窄屏/大字体下截断 label
          // 优先保住滑块可操作性。
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.4,
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          // 间距与左侧 icon→文字一致（16px），三种间隔统一：
          // icon |16| label |16| slider(full remaining)
          const SizedBox(width: 16),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                // 与特效面板滑杆同款配色
                trackHeight: 3,
                // 小 thumb（5px）：减小覆盖轨道端点的视觉，轨道
                // 更贴近两侧；track 已因 padding 非空而全宽
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5),
                activeTrackColor: accent,
                inactiveTrackColor: AppTheme.textTertiary.withValues(
                  alpha: 0.3,
                ),
                thumbColor: accent,
                overlayColor: accent.withValues(alpha: 0.08),
                // 去掉 Slider 默认 16px 横向 padding：贴齐标签
                padding: EdgeInsets.zero,
              ),
              child: Slider(value: value, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}
