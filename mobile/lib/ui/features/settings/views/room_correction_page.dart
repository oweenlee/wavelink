import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../data/services/file_picker_service.dart';
import '../../../../data/services/rust_service.dart' as rs;
import '../../../../l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../playback/view_models/audio_player_provider.dart';
import '../../playback/view_models/playback_controller.dart';
import '../view_models/dsp_provider.dart';

/// 房间校正页：REW 测量曲线 → 校正 FIR → 应用到 DSP 卷积级。
///
/// 流程：导入 REW 频响导出（.txt/.csv 或粘贴）→ 预览测量曲线 →
/// 调整参数 → 生成并应用（Rust 离线计算 FIR，存沙盒 WAV 后 load_ir）。
class RoomCorrectionPage extends ConsumerStatefulWidget {
  const RoomCorrectionPage({super.key});

  @override
  ConsumerState<RoomCorrectionPage> createState() => _RoomCorrectionPageState();
}

class _RoomCorrectionPageState extends ConsumerState<RoomCorrectionPage> {
  /// REW 原始文本（导入/粘贴后保存，生成时传给 Rust）
  String? _rewText;

  /// 解析出的测量曲线（预览 + 状态展示）
  List<rs.FreqPoint> _measured = const [];

  /// 校正配置（initState 从 Rust 取默认值，之后本地维护副本）
  rs.CorrectionConfig? _cfg;

  /// 生成进行中（按钮 loading）
  bool _generating = false;

  /// 最近一次生成报告（展示给用户）
  rs.RoomCorrectionResult? _report;

  @override
  void initState() {
    super.initState();
    _loadDefaultConfig();
  }

  Future<void> _loadDefaultConfig() async {
    final controller = ref.read(playbackControllerProvider);
    final cfg = await controller.defaultCorrectionConfig();
    if (!mounted) return;
    setState(() => _cfg = cfg);
  }

  rs.CorrectionConfig? get _config => _cfg;

  // ── 导入 ──

  Future<void> _importFromFile() async {
    final l10n = AppLocalizations.of(context);
    final paths = await FilePickerService.pickFiles(
      extensions: const ['txt', 'csv'],
      multiple: false,
    );
    if (paths.isEmpty) return;
    try {
      final text = await File(paths.first).readAsString();
      if (!mounted) return;
      await _loadRewText(text);
    } catch (e) {
      if (!mounted) return;
      _showError('${l10n.roomCorrectionReadFileError}: $e');
    }
  }

  Future<void> _pasteRewText() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          l10n.roomCorrectionPaste,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: TextField(
          controller: controller,
          maxLines: 10,
          minLines: 5,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontFamily: 'JetBrainsMono',
            fontSize: 11,
          ),
          decoration: InputDecoration(
            hintText: 'Freq (Hz), Level (dB)\n20.0, -1.5\n…',
            hintStyle: const TextStyle(color: AppTheme.textTertiary),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: AccentScope.of(context),
                width: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              l10n.cancel,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await _loadRewText(text);
  }

  /// 解析 REW 文本并保存：失败（点数不足/格式错误）提示原因
  Future<void> _loadRewText(String text) async {
    try {
      final points = await ref
          .read(playbackControllerProvider)
          .parseRewText(text);
      if (!mounted) return;
      setState(() {
        _rewText = text;
        _measured = points;
        _report = null;
      });
    } catch (e) {
      if (!mounted) return;
      _showError(e.toString());
    }
  }

  // ── 生成 / 清除 ──

  Future<void> _generate() async {
    final l10n = AppLocalizations.of(context);
    final text = _rewText;
    final cfg = _config;
    if (text == null || cfg == null) {
      _showError(l10n.roomCorrectionNoData);
      return;
    }
    setState(() => _generating = true);
    try {
      final report = await ref
          .read(playbackControllerProvider)
          .generateAndApplyRoomCorrection(rewTxt: text, config: cfg);
      if (!mounted) return;
      setState(() {
        _generating = false;
        _report = report;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.roomCorrectionResult,
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          backgroundColor: AppTheme.surfaceHigh,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      _showError(l10n.roomCorrectionLoadError(e.toString()));
    }
  }

  Future<void> _clear() async {
    await ref.read(playbackControllerProvider).clearRoomCorrection();
    if (!mounted) return;
    setState(() => _report = null);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: AppTheme.textPrimary)),
        backgroundColor: AppTheme.danger,
      ),
    );
  }

  // ── 参数维护（CorrectionConfig 不可变，逐字段复制构造）──

  void _updateCfg(rs.CorrectionConfig? next) {
    if (next != null) setState(() => _cfg = next);
  }

  rs.CorrectionConfig _cfgWith({
    String? target,
    int? taps,
    double? maxCutDb,
    double? nullLimitDb,
    double? freqMin,
    double? freqMax,
    bool? psychoWeighting,
    double? headroomDb,
  }) => rs.CorrectionConfig(
    target: target ?? _config!.target,
    taps: taps ?? _config!.taps,
    maxCutDb: maxCutDb ?? _config!.maxCutDb,
    nullLimitDb: nullLimitDb ?? _config!.nullLimitDb,
    freqMin: freqMin ?? _config!.freqMin,
    freqMax: freqMax ?? _config!.freqMax,
    psychoWeighting: psychoWeighting ?? _config!.psychoWeighting,
    smoothingOctave: _config!.smoothingOctave,
    headroomDb: headroomDb ?? _config!.headroomDb,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = AccentScope.of(context);
    // 状态在 dspProvider：watch 它即可响应式刷新，不能经 select 回调读取
    //（roomIrPath getter 内部会 read dspProvider，select 回调中禁止）
    final active = ref.watch(dspProvider).roomIrPath != null;
    final cfg = _config;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l10n.roomCorrection),
        centerTitle: true,
        backgroundColor: AppTheme.surfaceDark,
        leading: IconButton(
          icon: const Icon(
            LucideIcons.arrowLeft,
            color: AppTheme.textSecondary,
          ),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
          children: [
            Text(
              l10n.roomCorrectionHint,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: AppTheme.textTertiary.withValues(alpha: 0.9),
              ),
            ),
            // Bit-perfect 开启时 DSP 整链绕过，提示用户校正不会生效
            if (ref.watch(playerProvider.select((s) => s.bitPerfect)))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.warn.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.warn.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.triangleAlert,
                        size: 14,
                        color: AppTheme.warn,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.roomCorrectionBitPerfectWarn,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.warn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),

            // ── 导入 ──
            _Card(
              children: [
                _ActionButton(
                  icon: LucideIcons.fileUp,
                  label: l10n.roomCorrectionImport,
                  onTap: _importFromFile,
                ),
                const SizedBox(height: 8),
                _ActionButton(
                  icon: LucideIcons.clipboardPaste,
                  label: l10n.roomCorrectionPaste,
                  onTap: _pasteRewText,
                ),
                if (_measured.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _DataBadge(
                    text:
                        '${l10n.roomCorrectionValidPoints(_measured.length)}'
                        '  ·  '
                        '${l10n.roomCorrectionFreqSpan(_measured.last.freq.round(), _measured.first.freq.round())}',
                    color: accent,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),

            // ── 测量曲线预览 ──
            if (_measured.isNotEmpty) ...[
              _Card(
                title: l10n.roomCorrectionPreview,
                children: [
                  SizedBox(
                    height: 160,
                    child: _FreqCurveChart(
                      points: _measured,
                      freqMin: cfg?.freqMin ?? 20,
                      freqMax: cfg?.freqMax ?? 16000,
                      accent: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // ── 参数 ──
            if (cfg != null) ...[
              _Card(
                title: l10n.roomCorrectionTarget,
                children: [
                  Row(
                    children: [
                      _TargetOption(
                        label: l10n.roomCorrectionTargetFlat,
                        selected: cfg.target == 'flat',
                        accent: accent,
                        onTap: () => _updateCfg(_cfgWith(target: 'flat')),
                      ),
                      const SizedBox(width: 10),
                      _TargetOption(
                        label: l10n.roomCorrectionTargetHarman,
                        selected: cfg.target == 'harman_tilt',
                        accent: accent,
                        onTap: () =>
                            _updateCfg(_cfgWith(target: 'harman_tilt')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.roomCorrectionTargetHint,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.textTertiary.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _Card(
                title: l10n.roomCorrectionTaps,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final taps in const [4096, 8192, 16384, 32768])
                        _ChipOption(
                          label: '$taps',
                          selected: cfg.taps == taps,
                          accent: accent,
                          onTap: () => _updateCfg(_cfgWith(taps: taps)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.roomCorrectionTapsHint,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.textTertiary.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _Card(
                children: [
                  _ParamSlider(
                    label: l10n.roomCorrectionMaxCut,
                    value: cfg.maxCutDb,
                    min: 3,
                    max: 21,
                    divisions: 18,
                    unit: ' dB',
                    accent: accent,
                    onChanged: (v) => _updateCfg(_cfgWith(maxCutDb: v)),
                  ),
                  _ParamSlider(
                    label: l10n.roomCorrectionNullLimit,
                    value: cfg.nullLimitDb,
                    min: 0,
                    max: 9,
                    divisions: 18,
                    unit: ' dB',
                    accent: accent,
                    onChanged: (v) => _updateCfg(_cfgWith(nullLimitDb: v)),
                    hint: l10n.roomCorrectionNullLimitHint,
                  ),
                  _ParamSlider(
                    label: l10n.roomCorrectionHeadroom,
                    value: cfg.headroomDb,
                    min: 1,
                    max: 12,
                    divisions: 22,
                    unit: ' dB',
                    accent: accent,
                    onChanged: (v) => _updateCfg(_cfgWith(headroomDb: v)),
                    hint: l10n.roomCorrectionHeadroomHint,
                  ),
                  _FreqRangeSlider(
                    freqMin: cfg.freqMin,
                    freqMax: cfg.freqMax,
                    accent: accent,
                    onChanged: (min, max) =>
                        _updateCfg(_cfgWith(freqMin: min, freqMax: max)),
                  ),
                  _SwitchRow(
                    label: l10n.roomCorrectionPsycho,
                    value: cfg.psychoWeighting,
                    accent: accent,
                    onChanged: (v) => _updateCfg(_cfgWith(psychoWeighting: v)),
                    hint: l10n.roomCorrectionPsychoHint,
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // ── 生成 / 清除 ──
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black87,
                disabledBackgroundColor: AppTheme.surfaceHigh,
                disabledForegroundColor: AppTheme.textTertiary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _generating || _rewText == null || cfg == null
                  ? null
                  : _generate,
              child: _generating
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.roomCorrectionGenerating),
                      ],
                    )
                  : Text(l10n.roomCorrectionGenerate),
            ),

            // ── 状态 / 报告 ──
            const SizedBox(height: 12),
            _StatusRow(active: active, report: _report, l10n: l10n),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.danger,
                    side: BorderSide(
                      color: AppTheme.danger.withValues(alpha: 0.4),
                    ),
                  ),
                  onPressed: _clear,
                  icon: const Icon(LucideIcons.trash2, size: 16),
                  label: Text(l10n.roomCorrectionClear),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── 视觉组件 ──────────────────────────────────────────────

/// 卡片容器（可选小标题）
class _Card extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const _Card({this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
          ],
          ...children,
        ],
      ),
    );
  }
}

/// 导入按钮（图标 + 文案）
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.highlight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.textSecondary, size: 18),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数据徽标（点数 / 频段）
class _DataBadge extends StatelessWidget {
  final String text;
  final Color color;

  const _DataBadge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}

/// 目标曲线二选一
class _TargetOption extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _TargetOption({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.14)
                : AppTheme.highlight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.5)
                  : AppTheme.divider,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? accent : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// tap 数选择 chip
class _ChipOption extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _ChipOption({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.14) : AppTheme.highlight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.5) : AppTheme.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? accent : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 带数值尾巴的参数滑块
class _ParamSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String unit;
  final String? hint;
  final Color accent;
  final ValueChanged<double> onChanged;

  const _ParamSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.unit,
    this.hint,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final valueText = value == value.roundToDouble()
        ? '${value.round()}'
        : value.toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            Text(
              '$valueText$unit',
              style: WlText.mono(
                fontSize: 12,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: accent,
            inactiveTrackColor: AppTheme.textTertiary.withValues(alpha: 0.3),
            thumbColor: accent,
            overlayColor: accent.withValues(alpha: 0.08),
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              hint!,
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.textTertiary.withValues(alpha: 0.85),
              ),
            ),
          ),
      ],
    );
  }
}

/// 校正频率范围（对数 RangeSlider）
class _FreqRangeSlider extends StatelessWidget {
  final double freqMin;
  final double freqMax;
  final Color accent;
  final void Function(double, double) onChanged;

  const _FreqRangeSlider({
    required this.freqMin,
    required this.freqMax,
    required this.accent,
    required this.onChanged,
  });

  String _fmt(double v) {
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}kHz';
    return '${v.round()}Hz';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                AppLocalizations.of(context).roomCorrectionFreqRange,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            Text(
              '${_fmt(freqMin)} - ${_fmt(freqMax)}',
              style: WlText.mono(
                fontSize: 12,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: accent,
            inactiveTrackColor: AppTheme.textTertiary.withValues(alpha: 0.3),
            thumbColor: accent,
            overlayColor: accent.withValues(alpha: 0.08),
            trackHeight: 3,
          ),
          child: RangeSlider(
            values: RangeValues(
              freqMin.clamp(20, 20000),
              freqMax.clamp(20, 20000),
            ),
            min: 20,
            max: 20000,
            onChanged: (v) => onChanged(v.start, v.end),
          ),
        ),
      ],
    );
  }
}

/// 开关行
class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final String? hint;
  final Color accent;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    this.hint,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: accent.withValues(alpha: 0.4),
              activeThumbColor: accent,
              inactiveTrackColor: AppTheme.textTertiary.withValues(alpha: 0.3),
            ),
          ],
        ),
        if (hint != null)
          Text(
            hint!,
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textTertiary.withValues(alpha: 0.85),
            ),
          ),
      ],
    );
  }
}

/// 状态行 + 生成报告
class _StatusRow extends StatelessWidget {
  final bool active;
  final rs.RoomCorrectionResult? report;
  final AppLocalizations l10n;

  const _StatusRow({
    required this.active,
    required this.report,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = active ? AppTheme.ok : AppTheme.textTertiary;
    final statusText = active
        ? l10n.roomCorrectionActive
        : l10n.roomCorrectionOff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              active ? LucideIcons.checkCircle2 : LucideIcons.circle,
              size: 14,
              color: statusColor,
            ),
            const SizedBox(width: 6),
            Text(
              statusText,
              style: TextStyle(fontSize: 12, color: statusColor),
            ),
            if (report != null) ...[
              const SizedBox(width: 14),
              Text(
                l10n.roomCorrectionIrLength('${report!.ir.length}'),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ],
        ),
        if (report != null) ...[
          const SizedBox(height: 6),
          Text(
            report!.appliedGainDb < 0
                ? l10n.roomCorrectionGainHint(
                    report!.appliedGainDb.toStringAsFixed(1),
                  )
                : l10n.roomCorrectionGainHintMerge(
                    '+${report!.appliedGainDb.toStringAsFixed(1)}',
                  ),
            style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
          ),
        ],
      ],
    );
  }
}

/// 测量曲线预览：log 频率 x 轴，dB y 轴，校正范围背景高亮
class _FreqCurveChart extends StatelessWidget {
  final List<rs.FreqPoint> points;
  final double freqMin;
  final double freqMax;
  final Color accent;

  const _FreqCurveChart({
    required this.points,
    required this.freqMin,
    required this.freqMax,
    required this.accent,
  });

  static const double _xMin = 10; // Hz（log 轴下限）
  static const double _xMax = 20000; // Hz（log 轴上限）

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CurvePainter(
        points: points,
        freqMin: freqMin,
        freqMax: freqMax,
        accent: accent,
      ),
      size: Size.infinite,
    );
  }
}

class _CurvePainter extends CustomPainter {
  final List<rs.FreqPoint> points;
  final double freqMin;
  final double freqMax;
  final Color accent;

  _CurvePainter({
    required this.points,
    required this.freqMin,
    required this.freqMax,
    required this.accent,
  });

  double _x(double freq, Size size) =>
      (math.log(freq) - math.log(_FreqCurveChart._xMin)) /
      (math.log(_FreqCurveChart._xMax) - math.log(_FreqCurveChart._xMin)) *
      size.width;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final dbMin = points.map((p) => p.levelDb).reduce(math.min);
    final dbMax = points.map((p) => p.levelDb).reduce(math.max);
    final span = (dbMax - dbMin).abs() < 0.5 ? 1.0 : dbMax - dbMin;
    const padTop = 8.0;
    const padBottom = 18.0;

    double y(double db) =>
        padTop + (dbMax - db) / span * (size.height - padTop - padBottom);

    // 校正范围背景
    final rangeRect = Rect.fromLTRB(
      _x(freqMin, size),
      0,
      _x(freqMax, size),
      size.height,
    );
    canvas.drawRect(rangeRect, Paint()..color = accent.withValues(alpha: 0.07));

    // 0dB 参考线
    if (dbMin < 0 && dbMax > 0) {
      final dy = y(0);
      canvas.drawLine(
        Offset(0, dy),
        Offset(size.width, dy),
        Paint()
          ..color = AppTheme.textTertiary.withValues(alpha: 0.35)
          ..strokeWidth = 0.8,
      );
    }

    // 折线 + 渐变填充
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final dx = _x(p.freq, size);
      final dy = y(p.levelDb);
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 频率轴刻度（100 / 1k / 10k）
    final labelPaint = TextPainter(
      text: const TextSpan(
        text: '',
        style: TextStyle(color: AppTheme.textTertiary, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    );
    for (final f in const [100.0, 1000.0, 10000.0]) {
      final dx = _x(f, size);
      labelPaint.text = TextSpan(
        text: f >= 1000 ? '${(f / 1000).round()}k' : '${f.round()}',
        style: const TextStyle(color: AppTheme.textTertiary, fontSize: 9),
      );
      labelPaint.layout();
      labelPaint.paint(
        canvas,
        Offset(dx - labelPaint.width / 2, size.height - 14),
      );
    }
  }

  @override
  bool shouldRepaint(_CurvePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.freqMin != freqMin ||
      oldDelegate.freqMax != freqMax ||
      oldDelegate.accent != accent;
}
