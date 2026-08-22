import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_settings_provider.dart';
import '../services/diagnostics_provider.dart';
import '../services/dsp_settings_provider.dart';
import '../services/locale_provider.dart';
import '../services/player_providers.dart';
import '../src/rust/api/room.dart' as frb_room;
import '../widgets/settings_controls.dart';
import '../widgets/settings_rail.dart';
import '../widgets/settings_section.dart';
import '../widgets/setting_tiles.dart';

/// 设置页（桌面端）：语言 / 数据管理 + 音频输出 / DSP / 诊断。
///
/// 布局「左侧导航 + 右侧内容」主从结构。本组件是**纯视图层**：
/// 业务状态与持久化在 `services/*_settings_provider.dart`（对齐 mobile
/// `features/settings/view_models/` 的 Notifier 模式），文案统一走 l10n。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _active = 0;
  Timer? _diagTimer;

  /// 输出采样率固定档位（行业标准值，杜绝非法输入）。
  static const _sampleRates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000];

  /// 最常用档位（星标提示）：CD 标准与视频/流媒体标准。
  static const _commonRates = {44100, 48000};

  static const _locales = ['system', 'zh', 'ja', 'de', 'en'];
  static const _presets = [
    'flat', 'rock', 'pop', 'dance', 'classical', 'soft',
    'full_bass', 'full_treble', 'techno', 'vocals'
  ];

  @override
  void initState() {
    super.initState();
    ref.read(diagnosticsProvider.notifier).refresh();
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_active == 3) ref.read(diagnosticsProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _diagTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engineNull = !ref.watch(playerProvider.select((s) => s.engineReady));
    final audio = ref.watch(audioSettingsProvider);

    return Scaffold(
      backgroundColor: AppTheme.s1,
      body: Row(
        children: [
          SettingsRail(
            activeIndex: _active,
            engineReady: !engineNull,
            onSelect: (i) => setState(() => _active = i),
          ),
          Expanded(
            child: SettingsSectionContent(
              section: kSettingsSections[_active],
              engineNull: engineNull,
              // 音频/DSP 分区提供一键恢复默认
              onReset: _active == 1 ? _resetAudio : (_active == 2 ? _resetDsp : null),
              child: _activeContent(engineNull, audio),
            ),
          ),
        ],
      ),
    );
  }

  Widget _activeContent(bool engineNull, AudioSettingsState audio) {
    switch (_active) {
      case 0:
        return _buildGeneral();
      case 1:
        return _buildAudio(engineNull, audio);
      case 2:
        return _buildDsp();
      default:
        return _buildDiag(engineNull, audio);
    }
  }

  // ───────────────────────── 通用 ─────────────────────────

  Widget _buildGeneral() {
    final l = AppLocalizations.of(context);
    final mode = ref.watch(localeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroup(
          icon: LucideIcons.languages,
          title: l.settingsGroupLanguage,
          description: l.settingsGroupLanguageDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.globe,
              title: l.settingsDisplayLanguage,
              description: l.settingsDisplayLanguageDesc,
              trailing: SettingDropdown<String>(
                value: mode,
                onChanged: (v) {
                  if (v != null) {
                    ref.read(localeProvider.notifier).setMode(v);
                  }
                },
                items: _locales
                    .map((k) => DropdownMenuItem(
                          value: k,
                          child: Text(_localeLabel(l, k),
                              style: const TextStyle(
                                  color: AppTheme.textPrimary, fontSize: 13)),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.database,
          title: l.settingsGroupData,
          description: l.settingsGroupDataDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.trash2,
              title: l.settingsClearAll,
              description: l.settingsClearAllDesc,
              iconColor: AppTheme.danger,
              trailing: OutlinedButton.icon(
                onPressed: () => _confirmClearAll(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  side: const BorderSide(color: AppTheme.danger),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(LucideIcons.trash2, size: 15),
                label: Text(l.settingsClearAll),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _localeLabel(AppLocalizations l, String code) => switch (code) {
        'system' => l.langSystem,
        'zh' => l.langZh,
        'ja' => l.langJa,
        'de' => l.langDe,
        _ => l.langEn,
      };

  // ───────────────────────── 音频输出 ─────────────────────────

  Widget _buildAudio(bool engineNull, AudioSettingsState audio) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroup(
          icon: LucideIcons.headphones,
          title: l.settingsGroupOutputDevice,
          description: l.settingsGroupOutputDeviceDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.speaker,
              title: l.settingsDevice,
              description:
                  audio.selectedDevice ?? l.settingsSystemDefaultOutput,
              trailing: SettingDropdown<String?>(
                value: audio.selectedDevice,
                hint: l.settingsSystemDefault,
                onChanged: (v) =>
                    ref.read(audioSettingsProvider.notifier).selectDevice(v),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l.settingsSystemDefault,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13)),
                  ),
                  ...audio.devices.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d,
                      child: Text(d,
                          style: const TextStyle(
                              color: AppTheme.textPrimary, fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
            SettingTile(
              icon: LucideIcons.gauge,
              title: l.settingsCurrentStatus,
              child: TechChips(children: [
                TechChip(
                    label: l.settingsMode,
                    value: audio.exclusive
                        ? l.settingsModeExclusive
                        : l.settingsModeShared),
                TechChip(
                    label: l.settingsSampleRate,
                    value: audio.actualSampleRate != null
                        ? '${audio.actualSampleRate} Hz'
                        : '—'),
              ]),
            ),
            if (Platform.isWindows || Platform.isMacOS)
              SettingTile(
                key: const Key('sw_exclusive'),
                icon: LucideIcons.lock,
                title: Platform.isWindows
                    ? l.settingsExclusiveWasapi
                    : l.settingsExclusiveHog,
                description: l.settingsExclusiveDesc,
                trailing: AccentSwitch(
                  value: audio.exclusive,
                  onChanged: (v) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final err = await ref
                        .read(audioSettingsProvider.notifier)
                        .setExclusive(v);
                    if (err != null && mounted) {
                      messenger.showSnackBar(SnackBar(
                          content: Text(l.settingsExclusiveFailed(err))));
                    }
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.waves,
          title: l.settingsSampleRate,
          description: l.settingsGroupSampleRateDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.hash,
              title: l.settingsOutputSampleRate,
              description: l.settingsSrHint,
              // 下拉与标题同行（trailing），选中即应用；
              // Bit-Perfect 按源直通 → 联动禁用
              trailing: SettingDropdown<int>(
                key: const Key('sr_dropdown'),
                value: audio.sampleRatePref,
                width: 170,
                onChanged: audio.bitPerfect
                    ? null
                    : (v) async {
                        if (v == null) return;
                        final messenger = ScaffoldMessenger.of(context);
                        await ref
                            .read(audioSettingsProvider.notifier)
                            .applySampleRate(v);
                        if (mounted) {
                          messenger.showSnackBar(
                              SnackBar(content: Text(l.settingsSrApplied)));
                        }
                      },
                items: _sampleRates.map((r) {
                  final common = _commonRates.contains(r);
                  return DropdownMenuItem(
                    value: r,
                    child: Row(
                      children: [
                        Text('$r Hz',
                            style: const TextStyle(
                                color: AppTheme.textPrimary, fontSize: 13)),
                        // 44.1k/48k 为通用档位，加星标提示
                        if (common) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: l.settingsCommonRate,
                            child: const Icon(Icons.star_rounded,
                                size: 14, color: AppTheme.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.zap,
          title: l.settingsGroupAdvanced,
          description: l.settingsGroupAdvancedDesc,
          tiles: [
            SettingTile(
              key: const Key('sw_bitperfect'),
              icon: LucideIcons.shieldCheck,
              title: l.settingsBitPerfect,
              description: l.settingsBitPerfectDesc,
              trailing: AccentSwitch(
                value: audio.bitPerfect,
                onChanged: (v) async {
                  final messenger = ScaffoldMessenger.of(context);
                  final err = await ref
                      .read(audioSettingsProvider.notifier)
                      .setBitPerfect(v);
                  if (err != null && mounted) {
                    messenger.showSnackBar(SnackBar(
                        content: Text(l.settingsBitPerfectFailed(err))));
                  }
                },
              ),
            ),
            SettingTile(
              key: const Key('sw_autosr'),
              icon: LucideIcons.refreshCw,
              title: l.settingsAutoSr,
              description: audio.bitPerfect
                  ? l.settingsBitPerfectLocksSr
                  : l.settingsAutoSrDesc,
              trailing: AccentSwitch(
                value: audio.autoSampleRate,
                // Bit-Perfect 按源直通，自动采样率无意义 → 联动禁用
                onChanged: audio.bitPerfect
                    ? null
                    : (v) async {
                        final messenger = ScaffoldMessenger.of(context);
                        final err = await ref
                            .read(audioSettingsProvider.notifier)
                            .setAutoSampleRate(v);
                        if (err != null && mounted) {
                          messenger.showSnackBar(SnackBar(
                              content:
                                  Text(l.settingsAutoSrFailed(err))));
                        }
                      },
              ),
            ),
            SettingTile(
              icon: LucideIcons.shuffle,
              title: l.settingsCrossfade,
              description: l.settingsCrossfadeDesc,
              child: SliderWithLabel(
                value: audio.crossfadeMs,
                min: 0,
                max: 8000,
                divisions: 32,
                fmt: (v) => v == 0 ? l.settingsOff : '${v.round()} ms',
                onChanged: (v) => ref
                    .read(audioSettingsProvider.notifier)
                    .setCrossfade(v),
                onChangeEnd: (_) => ref
                    .read(audioSettingsProvider.notifier)
                    .persistCrossfade(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ───────────────────────── DSP 效果 ─────────────────────────

  Widget _buildDsp() {
    final l = AppLocalizations.of(context);
    final dsp = ref.watch(dspSettingsProvider);
    final n = ref.read(dspSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroup(
          icon: LucideIcons.expand,
          title: l.settingsGroupSpatial,
          description: l.settingsGroupSpatialDesc,
          tiles: [
            SettingTile(
              key: const Key('sw_立体声展宽'),
              icon: LucideIcons.moveHorizontal,
              title: l.settingsStereoWiden,
              description: l.settingsStereoWidenDesc,
              trailing: AccentSwitch(
                value: dsp.widenerOn,
                onChanged: n.toggleWidener,
              ),
            ),
            if (dsp.widenerOn)
              SettingTile(
                icon: LucideIcons.slidersHorizontal,
                title: l.settingsWidenWidth,
                child: SliderWithLabel(
                  value: dsp.widenerWidth,
                  min: 0,
                  max: 1,
                  fmt: (v) => v.toStringAsFixed(2),
                  onChanged: n.setWidenerWidth,
                  onChangeEnd: (_) => n.persistSliders(),
                ),
              ),
            SettingTile(
              key: const Key('sw_跨馈 (Crossfeed)'),
              icon: LucideIcons.headphones,
              title: l.settingsCrossfeed,
              description: l.settingsCrossfeedDesc,
              trailing: AccentSwitch(
                value: dsp.crossfeed,
                onChanged: n.setCrossfeed,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.activity,
          title: l.settingsGroupDynamics,
          description: l.settingsGroupDynamicsDesc,
          tiles: [
            SettingTile(
              key: const Key('sw_真峰值限幅 (Limiter)'),
              icon: LucideIcons.shield,
              title: l.settingsLimiter,
              description: l.settingsLimiterDesc,
              trailing: AccentSwitch(
                value: dsp.limiter,
                onChanged: n.setLimiter,
              ),
            ),
            SettingTile(
              icon: LucideIcons.grid2x2,
              title: l.settingsDither,
              description: l.settingsDitherDesc,
              trailing: AccentSwitch(
                value: dsp.dither,
                onChanged: n.setDither,
              ),
            ),
            SettingTile(
              icon: LucideIcons.audioWaveform,
              title: l.settingsNoiseShaping,
              description: l.settingsNoiseShapingDesc,
              trailing: AccentSwitch(
                value: dsp.noiseShaping,
                onChanged: n.setNoiseShaping,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.trendingUp,
          title: l.settingsGroupGainSpeed,
          description: l.settingsGroupGainSpeedDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.volume2,
              title: l.settingsReplayGain,
              description: l.settingsReplayGainDesc,
              child: SliderWithLabel(
                value: dsp.gain,
                min: -12,
                max: 12,
                fmt: (v) => '${v.toStringAsFixed(1)} dB',
                onChanged: n.setGain,
                onChangeEnd: (_) => n.persistSliders(),
              ),
            ),
            SettingTile(
              icon: LucideIcons.gauge,
              title: l.settingsPlaybackSpeed,
              description: l.settingsPlaybackSpeedDesc,
              child: SliderWithLabel(
                value: dsp.speed,
                min: 0.25,
                max: 4,
                fmt: (v) => '${v.toStringAsFixed(2)}x',
                onChanged: n.setSpeed,
                onChangeEnd: (_) => n.persistSliders(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.slidersVertical,
          title: l.settingsGroupEq,
          description: l.settingsGroupEqDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.listMusic,
              title: l.settingsEqPreset,
              description: l.settingsEqPresetDesc,
              trailing: SettingDropdown<String>(
                key: const Key('preset_dropdown'),
                value: dsp.preset,
                onChanged: (v) {
                  if (v != null) n.applyPreset(v);
                },
                items: _presets
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text(_presetLabel(l, p),
                              style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 13)),
                        ))
                    .toList(),
              ),
            ),
            SettingTile(
              icon: LucideIcons.headphones,
              title: l.settingsAutoEqModel,
              description:
                  dsp.autoEq.isEmpty ? l.settingsAutoEqDisabled : dsp.autoEq,
              trailing: InkWell(
                key: const Key('autoeq_picker'),
                onTap: _pickAutoEq,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.s3,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.highlightStrong),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l.settingsPick,
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                      const SizedBox(width: 6),
                      const Icon(LucideIcons.chevronDown,
                          size: 14, color: AppTheme.textTertiary),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.audioLines,
          title: l.settingsGroupRoom,
          description: l.settingsGroupRoomDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.fileAudio,
              title: l.settingsFirIr,
              // 来源标记：REW 生成的临时 FIR（wavelink_correction_*）显式标注，
              // 用户能区分手动加载的文件与工具生成产物
              description: dsp.irPath.isEmpty
                  ? l.settingsNotLoaded
                  : (dsp.irPath.split('/').last.startsWith('wavelink_correction_')
                      ? '${l.settingsRewSource} · ${dsp.irPath.split('/').last}'
                      : dsp.irPath.split('/').last),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: _pickIr,
                    child: Text(l.settingsLoad),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('fir_clear'),
                    onPressed: () =>
                        ref.read(dspSettingsProvider.notifier).clearIr(),
                    child: Text(l.settingsClear),
                  ),
                ],
              ),
            ),
            SettingTile(
              icon: LucideIcons.wand2,
              title: l.settingsRewGenerate,
              description: l.settingsRewGenerateDesc,
              trailing: OutlinedButton.icon(
                onPressed: _generateRew,
                icon: const Icon(LucideIcons.wand2,
                    size: 15, color: AppTheme.textSecondary),
                label: Text(l.settingsGenerate),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _presetLabel(AppLocalizations l, String id) => switch (id) {
        'flat' => l.eqPresetFlat,
        'rock' => l.eqPresetRock,
        'pop' => l.eqPresetPop,
        'dance' => l.eqPresetDance,
        'classical' => l.eqPresetClassical,
        'soft' => l.eqPresetSoft,
        'full_bass' => l.eqPresetFullBass,
        'full_treble' => l.eqPresetFullTreble,
        'techno' => l.eqPresetTechno,
        _ => l.eqPresetVocals,
      };

  // ───────────────────────── 诊断 ─────────────────────────

  Widget _buildDiag(bool engineNull, AudioSettingsState audio) {
    final l = AppLocalizations.of(context);
    final diag = ref.watch(diagnosticsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 指标卡响应式：宽窗口横排三卡，窄窗口（<560）纵向堆叠防截断
        LayoutBuilder(builder: (context, c) {
          final cards = [
            MetricCard(
              icon: LucideIcons.gauge,
              label: 'UNDERRUN',
              value: '${diag.underrun}',
              valueColor: diag.underrun > 0 ? AppTheme.warn : AppTheme.ok,
            ),
            MetricCard(
              icon: LucideIcons.waves,
              label: l.settingsSampleRate,
              value: audio.actualSampleRate != null
                  ? '${audio.actualSampleRate} Hz'
                  : '—',
            ),
            MetricCard(
              icon: engineNull
                  ? LucideIcons.circleAlert
                  : LucideIcons.circleCheck,
              label: l.settingsEngineStatus,
              value: engineNull ? l.settingsNotLoaded : l.settingsReady,
              valueColor: engineNull ? AppTheme.warn : AppTheme.ok,
            ),
          ];
          if (c.maxWidth < 560) {
            return Column(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  cards[i],
                ],
              ],
            );
          }
          return Row(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: cards[i]),
              ],
            ],
          );
        }),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.terminal,
          title: l.settingsGroupRuntime,
          description: l.settingsGroupRuntimeDesc,
          tiles: [
            SettingTile(
              icon: LucideIcons.music,
              title: l.settingsCurrentTrack,
              child: SelectableText(
                diag.currentPath.isEmpty ? '—' : diag.currentPath,
                style: WlText.mono(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
            SettingTile(
              icon: LucideIcons.alertCircle,
              title: l.settingsLastError,
              child: SelectableText(
                diag.lastError.isEmpty ? l.settingsNone : diag.lastError,
                style: WlText.mono(
                  fontSize: 12,
                  color: diag.lastError.isEmpty
                      ? AppTheme.textTertiary
                      : AppTheme.warn,
                ),
              ),
            ),
            SettingTile(
              icon: LucideIcons.refreshCw,
              title: l.settingsAutoRefresh,
              description: l.settingsAutoRefreshDesc,
              trailing: OutlinedButton.icon(
                onPressed: () =>
                    ref.read(diagnosticsProvider.notifier).refresh(),
                icon: const Icon(LucideIcons.rotateCw,
                    size: 15, color: AppTheme.textSecondary),
                label: Text(l.settingsRefreshNow),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ───────────────────────── 交互（对话框 / 文件选择） ─────────────────────────

  /// 音频输出恢复默认；失败时提示，成功静默（状态已可见回弹）。
  Future<void> _resetAudio() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final err =
        await ref.read(audioSettingsProvider.notifier).resetOutput();
    if (err != null && mounted) {
      messenger.showSnackBar(
          SnackBar(content: Text(l.settingsBitPerfectFailed(err))));
    } else if (mounted) {
      messenger.showSnackBar(
          SnackBar(content: Text(l.settingsResetDone)));
    }
  }

  /// DSP 恢复默认。
  Future<void> _resetDsp() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(dspSettingsProvider.notifier).resetAll();
    if (mounted) {
      messenger.showSnackBar(SnackBar(content: Text(l.settingsResetDone)));
    }
  }

  Future<void> _pickIr() async {
    final x = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'IR', extensions: ['wav']),
      ],
    );
    if (x != null) {
      await ref.read(dspSettingsProvider.notifier).loadIr(x.path);
    }
  }

  /// AutoEQ 型号选择。
  Future<void> _pickAutoEq() async {
    final l = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final catalog =
        await ref.read(dspSettingsProvider.notifier).autoEqCatalog();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.s2,
        title: Text(l.settingsAutoEqModel,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
        content: SizedBox(
          width: 380,
          height: 360,
          // Consumer 订阅选中态：对话框打开期间状态变化也能刷新高亮
          child: Consumer(builder: (ctx, ref2, _) {
            final current = ref2.watch(dspSettingsProvider).autoEq;
            return ListView(
              shrinkWrap: true,
              children: [
                AutoEqTile(
                  label: l.settingsAutoEqOff,
                  selected: current.isEmpty,
                  accent: accent,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    ref.read(dspSettingsProvider.notifier).setAutoEq(null);
                  },
                ),
                ...catalog.map((m) => AutoEqTile(
                      label: m,
                      selected: m == current,
                      accent: accent,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        ref
                            .read(dspSettingsProvider.notifier)
                            .setAutoEq(m);
                      },
                    )),
              ],
            );
          }),
        ),
      ),
    );
    if (mounted && ref.read(dspSettingsProvider).autoEq.isNotEmpty) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text(l.settingsAutoEqApplied(
              ref.read(dspSettingsProvider).autoEq))));
    }
  }

  /// 从 REW 频响测量文本生成校正 FIR。
  Future<void> _generateRew() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final x = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: l.settingsRewFile, extensions: const ['txt']),
      ],
    );
    if (x == null || !mounted) return;
    try {
      final text = await File(x.path).readAsString();
      final pts = await frb_room.parseRewText(text: text);
      if (pts.isEmpty) {
        messenger.showSnackBar(
            SnackBar(content: Text(l.settingsRewNoPoints)));
        return;
      }
      final config = await frb_room.defaultCorrectionConfig();
      final sr =
          ref.read(audioSettingsProvider).actualSampleRate ?? 44100;
      final result = await frb_room.generateRoomCorrection(
        rewTxt: text,
        config: config,
        sampleRate: sr,
      );
      final irFile = File(
          '${Directory.systemTemp.path}/wavelink_correction_${DateTime.now().millisecondsSinceEpoch}.wav');
      await frb_room.saveIrWav(
          ir: result.ir, sampleRate: sr, path: irFile.path);
      await ref.read(dspSettingsProvider.notifier).loadIr(irFile.path);
      messenger.showSnackBar(SnackBar(
        content: Text(l.settingsRewGenerated(
            result.points.toInt(), result.appliedGainDb.toStringAsFixed(1))),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l.settingsGenerateFailed(e.toString()))));
    }
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.s2,
        title: Text(l.clearAllConfirmTitle,
            style: const TextStyle(color: AppTheme.textPrimary)),
        content: Text(l.clearAllConfirmBody,
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.btnCancel,
                style: const TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.btnConfirmClear,
                style: const TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(playerProvider.notifier).clearAllData();
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l.snackAllCleared)));
      }
    }
  }
}
