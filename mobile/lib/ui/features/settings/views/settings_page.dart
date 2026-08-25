import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/cache_cleaner.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/wl_toggle.dart';
import '../../library/view_models/library_provider.dart';
import '../../playback/view_models/playback_controller.dart';
import '../../playback/view_models/audio_player_provider.dart';
import '../view_models/dsp_provider.dart';
import '../view_models/locale_provider.dart';
import '../view_models/package_info_provider.dart';
import '../../paywall/view_models/subscription_provider.dart';

/// Pro 功能门控：未订阅（且订阅状态已查询完成）时改道付费墙，
/// 否则执行原动作。状态未就绪前放行，避免启动时误弹。
void _requirePro(BuildContext context, WidgetRef ref, VoidCallback action) {
  final sub = ref.read(subscriptionProvider);
  if (sub.isPro || !sub.ready) {
    action();
  } else {
    context.push('/paywall');
  }
}

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
          (ctx) => _RowShell(isFirst: isFirst, isLast: isLast, child: row(ctx)),
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

    addSection(l10n.settingsStorage, [(_) => const _CacheRow()]);

    addSection(l10n.language, [(_) => const _LanguageItem()]);

    addSection(l10n.settingsAbout, [
      (ctx) => const _ProRow(),
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
      badge: const _ProBadge(),
      onTap: () => _requirePro(context, ref, () => context.push('/autoeq')),
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
      badge: const _ProBadge(),
      onTap: () =>
          _requirePro(context, ref, () => context.push('/room-correction')),
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
      onChanged: (_) => _requirePro(context, ref, () {
        ref.read(playbackControllerProvider).setBitPerfect(!bitPerfect);
      }),
      badge: const _ProBadge(),
      subtitle: _bitPerfectStatus(l10n, bitPerfect, telemetry, dsp, replayGain),
    );
  }
}

class _CoverBlurRow extends ConsumerStatefulWidget {
  const _CoverBlurRow();

  @override
  ConsumerState<_CoverBlurRow> createState() => _CoverBlurRowState();
}

class _CoverBlurRowState extends ConsumerState<_CoverBlurRow> {
  bool _dragging = false;
  double _lastHapticValue = -1;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(playerProvider.select((s) => s.coverBlur));
    return _SliderItem(
      icon: LucideIcons.droplets,
      label: l10n.coverBlur,
      value: value,
      showValue: _dragging,
      onChangeStart: (v) {
        setState(() => _dragging = true);
        _lastHapticValue = v;
      },
      onChanged: (v) {
        ref.read(playbackControllerProvider).setCoverBlur(v);
        // 在 0%、50%、100% 位置触发触觉反馈
        final rounded = (v * 100).round();
        if ((rounded == 0 || rounded == 50 || rounded == 100) &&
            (rounded - (_lastHapticValue * 100).round()).abs() > 1) {
          HapticFeedback.lightImpact();
          _lastHapticValue = v;
        }
      },
      onChangeEnd: (v) {
        setState(() => _dragging = false);
        // 松手时归零到最近的 5% 刻度
        final snapped = (v * 20).round() / 20;
        ref.read(playbackControllerProvider).setCoverBlur(snapped);
      },
    );
  }
}

/// 清理缓存行：展示四类缓存目录总占用，点击后弹确认框，删除曲库
/// 无引用的缓存文件（正在播放/使用的封面与下载不受影响）。
class _CacheRow extends ConsumerStatefulWidget {
  const _CacheRow();

  @override
  ConsumerState<_CacheRow> createState() => _CacheRowState();
}

class _CacheRowState extends ConsumerState<_CacheRow> {
  String _size = '';
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final bytes = await CacheCleaner.computeCacheBytes();
    if (!mounted) return;
    setState(() => _size = CacheCleaner.formatBytes(bytes));
  }

  Future<void> _confirmClear() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(l10n.clearCache),
        content: Text(l10n.clearCacheConfirm(_size)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.clearCache,
              style: const TextStyle(color: AppTheme.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    final songs = ref.read(libraryProvider).importedSongs;
    final refs = await CacheCleaner.collectReferencedFiles(songs);
    final freed = await CacheCleaner.clearUnreferencedCache(refs);
    if (!mounted) return;
    setState(() => _clearing = false);
    await _refresh();
    Fluttertoast.showToast(
      msg: freed == 0
          ? l10n.clearCacheNone
          : l10n.clearCacheDone(CacheCleaner.formatBytes(freed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _SettingItem(
      icon: _clearing ? LucideIcons.loader : LucideIcons.trash2,
      label: l10n.clearCache,
      trailing: _clearing ? '•••' : _size,
      onTap: _clearing ? null : _confirmClear,
    );
  }
}

/// WaveLink Pro 入口：已订阅显示激活状态，未订阅点击进付费墙。
class _ProRow extends ConsumerWidget {
  const _ProRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isPro = ref.watch(subscriptionProvider.select((s) => s.isPro));
    return _SettingItem(
      icon: LucideIcons.crown,
      label: l10n.paywallTitle,
      trailing: isPro ? l10n.proActive : null,
      onTap: () => context.push('/paywall'),
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
    final versionText = (v == null || v.isEmpty) ? '—' : 'v$v';
    return _SettingItem(
      icon: LucideIcons.info,
      label: l10n.version,
      trailing: versionText,
      onTap: v != null && v.isNotEmpty
          ? () async {
              HapticFeedback.lightImpact();
              try {
                await Clipboard.setData(ClipboardData(text: 'v$v'));
              } catch (_) {}
              Fluttertoast.showToast(
                msg: 'v$v',
                gravity: ToastGravity.BOTTOM,
                timeInSecForIosWeb: 2,
                backgroundColor: AppTheme.surfaceHigh,
                textColor: AppTheme.textPrimary,
                fontSize: 13,
              );
            }
          : null,
    );
  }
}

class _LanguageItem extends ConsumerWidget {
  const _LanguageItem();

  static const _options = ['system', 'zh', 'ja', 'ko', 'de', 'en'];

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
        case 'ko':
          return '한국어';
        case 'de':
          return 'Deutsch';
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
        case 'ko':
          return '한국어';
        case 'de':
          return 'Deutsch';
        case 'en':
          return 'English';
        default:
          return l10n.systemDefault;
      }
    }

    // 与曲库页 sheet 一致：走分支 Navigator（被 AppShell 的 Expanded 限定在
    // body 区域，底部正好落在常驻播放条上方），内容自适应高度而非固定 55%。
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: AppTheme.surfaceDark,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 拖拽把手（与 SheetShell 一致）
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.textTertiary.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              // 标题行（左对齐，与 SheetShell 一致）
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  l10n.language,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              const Divider(height: 1, color: AppTheme.textTertiary),
              // 选项列表：内容过多时内部滚动，否则自适应高度
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: _options.map((mode) {
                    final selected = localeMode == mode;
                    return Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? accent.withValues(alpha: 0.1)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ListTile(
                        leading: Icon(
                          selected
                              ? LucideIcons.checkCircle2
                              : LucideIcons.circle,
                          color: selected ? accent : AppTheme.textTertiary,
                          size: 20,
                        ),
                        title: Text(
                          labelFor(mode),
                          style: TextStyle(
                            fontSize: 15,
                            color: selected ? accent : AppTheme.textPrimary,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        dense: true,
                        onTap: () => Navigator.of(context).pop(mode),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((mode) {
      // 等 sheet 退场动画结束后再切语言，避免关闭过程中整棵 MaterialApp
      // 以新语言重建导致跳变卡顿
      if (mode != null) {
        ref.read(localeProvider.notifier).setMode(mode);
      }
    });
  }
}

/// bit-perfect 开关副标题：如实反映链路状态（偏好 + 实际速率 + DSP）。
/// 判定与 PlaybackController.effectiveBitPerfect 一致：速率匹配 + 无信号改动
/// （Android 还需 Exclusive 独占直通）；ReplayGain 属信号改动，开启时不算。
/// 用中性事实描述（带采样率数字）替代原「未生效/生效」的价值判断，
/// 避免误导用户以为是操作问题——多数情况是设备/文件组合不支持直出。
String _bitPerfectStatus(
  AppLocalizations l10n,
  bool bitPerfect,
  EngineTelemetry t,
  DspSettings dsp,
  bool replayGain,
) {
  if (!bitPerfect) return l10n.bitPerfectHint;
  final dspTouching =
      dsp.enabled || dsp.crossfeed || dsp.widener || dsp.limiter;
  final effective =
      t.fileRate > 0 &&
      t.fileRate == t.outputRate &&
      (!Platform.isAndroid || t.outputMode == 1) &&
      !dspTouching &&
      !replayGain;
  if (effective) {
    final rate = _fmtRate(t.outputRate);
    return Platform.isAndroid
        ? l10n.bitPerfectExclusiveActive(rate)
        : l10n.bitPerfectBitExactActive(rate);
  }
  final reasons = <String>[];
  if (t.fileRate > 0 && t.fileRate != t.outputRate) {
    reasons.add(
      l10n.bitPerfectResampling(_fmtRate(t.fileRate), _fmtRate(t.outputRate)),
    );
  }
  if (Platform.isAndroid && t.outputMode == 2) {
    reasons.add(l10n.bitPerfectShared);
  }
  if (dspTouching) {
    reasons.add(l10n.bitPerfectDspActive);
  }
  if (replayGain) {
    reasons.add(l10n.bitPerfectReplayGainActive);
  }
  if (reasons.isEmpty) return l10n.bitPerfectWaitPlay;
  return reasons.join(' · ');
}

/// 采样率 Hz → 人类可读（44100 → 44.1kHz，48000 → 48kHz，96000 → 96kHz）。
String _fmtRate(int hz) {
  if (hz <= 0) return '?';
  if (hz % 1000 == 0) return '${hz ~/ 1000}kHz';
  return '${(hz / 1000).toStringAsFixed(1)}kHz';
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

/// Pro 功能标识：未订阅（且状态已就绪）时显示小徽标，订阅成功后消失。
/// 行内只 select ready/isPro，购买完成自动刷新本行。
class _ProBadge extends ConsumerWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(
      subscriptionProvider.select((s) => s.ready && !s.isPro),
    );
    if (!locked) return const SizedBox.shrink();
    final accent = AccentScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        'PRO',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: accent,
          letterSpacing: 0.5,
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

  /// 行内 Pro 徽标（可选），渲染在标题右侧、trailing 之前。
  final Widget? badge;

  const _SettingItem({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    // MergeSemantics 把 icon+label+trailing 聚合成单一可点击节点：
    // VoiceOver/TalkBack 焦点落在整行，保留 button role 与 enabled 状态。
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onTap != null,
        child: InkWell(
          onTap: onTap,
          // 圆角匹配分组容器，墨水不溢出到外层
          borderRadius: BorderRadius.circular(14),
          splashColor: AppTheme.textTertiary.withValues(alpha: 0.1),
          highlightColor: AppTheme.textTertiary.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                if (badge != null) ...[
                  const SizedBox(width: 8),
                  badge!,
                ],
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
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

  /// 行内 Pro 徽标（可选），渲染在标题右侧、开关之前。
  final Widget? badge;

  const _SwitchItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        enabled: true,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          splashColor: AppTheme.textTertiary.withValues(alpha: 0.1),
          highlightColor: AppTheme.textTertiary.withValues(alpha: 0.05),
          onTap: () {
            HapticFeedback.lightImpact();
            onChanged(!value);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                if (badge != null) ...[
                  const SizedBox(width: 8),
                  badge!,
                ],
                const SizedBox(width: 8),
                WlToggle(
                  value: value,
                  onChanged: () {
                    HapticFeedback.lightImpact();
                    onChanged(!value);
                  },
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
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final bool showValue;

  const _SliderItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.showValue = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 22),
          const SizedBox(width: 16),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.4,
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                activeTrackColor: accent,
                inactiveTrackColor: AppTheme.textTertiary.withValues(
                  alpha: 0.3,
                ),
                thumbColor: accent,
                overlayColor: accent.withValues(alpha: 0.08),
                padding: EdgeInsets.zero,
              ),
              child: Slider(
                value: value,
                onChanged: onChanged,
                onChangeStart: onChangeStart,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
          if (showValue) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 36,
              child: Text(
                '${(value * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textTertiary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
