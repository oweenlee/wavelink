import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../features/playback/view_models/playback_provider.dart';
import '../../features/settings/view_models/dsp_provider.dart';
import '../theme/app_theme.dart';
import 'sheet_shell.dart';

class EffectsSheet extends StatelessWidget {
  const EffectsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final player = context.watch<PlaybackProvider>();
    final dsp = player.dspSettings;
    return SheetShell(
      title: l10n.soundSettings,
      builder: (scroll) {
        return ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
            // ── 10 段 EQ 区 ──
            _EqSection(),
            // ── DSP 效果列表 ──
            _SectionHeader(label: 'EFFECTS'),
            _EffectItem(
              icon: LucideIcons.vibrate,
              label: l10n.bauerCrossfeed,
              subtitle: 'Natural headphone speaker placement',
              enabled: dsp.crossfeed,
              onToggle: player.toggleCrossfeed,
            ),
            const _Divider(),
            _EffectItem(
              icon: LucideIcons.arrowRight,
              label: l10n.stereoWidening,
              subtitle: 'Widen the soundstage',
              enabled: dsp.widener,
              onToggle: player.toggleWidener,
            ),
            const _Divider(),
            _EffectItem(
              icon: LucideIcons.volume2,
              label: l10n.truePeakLimiter,
              subtitle: 'Prevent clipping on loud passages',
              enabled: dsp.limiter,
              onToggle: player.toggleLimiter,
            ),
            const _Divider(),
            _EffectItem(
              icon: LucideIcons.activity,
              label: l10n.tpdfDither,
              subtitle: 'Clean 16-bit downsampling',
              enabled: dsp.dither,
              onToggle: player.toggleDither,
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

// ── Section Header ──

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        label,
        style: WlText.mono(
          fontSize: 10,
          color: AppTheme.textTertiary,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

// ── 10 段 EQ ──

/// 10 段参量 EQ：竖滑块 + dB 值 + 预设 chips + 贝塞尔曲线连线。
/// 状态与预设表均由 [DspProvider] 持有（与 audio-core 引擎对齐），
/// 调整实时下发引擎出声。直接 watch [DspProvider] 而非 PlaybackProvider，
/// 避免播放进度 250ms tick 带动滑块重建。
class _EqSection extends StatelessWidget {
  String _bandLabel(double hz) {
    if (hz >= 1000) return '${(hz / 1000).round()}k';
    return '${hz.round()}';
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final dsp = context.watch<DspProvider>();
    final values = dsp.eqValues;
    final activePreset = dsp.eqPreset;
    final freqs = DspProvider.eqFrequencies;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // header（与 EFFECTS 标题统一样式与左对齐）
        const _SectionHeader(label: 'EQUALIZER'),
        // 预设 chips（水平可滚动）
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: DspProvider.eqPresets.keys.map((p) {
              final active = activePreset == p;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => dsp.applyEqPreset(p),
                  child: Container(
                    // alignment 居中：chips 被 ListView 拉满高度时文字不再偏上
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: active
                          ? accent.withValues(alpha: 0.15)
                          : AppTheme.s4.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                      border: active
                          ? Border.all(
                              color: accent.withValues(alpha: 0.4),
                            )
                          : null,
                    ),
                    child: Text(
                      p,
                      style: WlText.mono(
                        fontSize: 10,
                        color: active ? accent : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        // 10 条竖滑块 + 曲线

         SizedBox(

            height: 180,
            child: Padding(
              padding: const EdgeInsets.only(left: 12,right: 12,top: 4,bottom: 4),
              child: Stack(
                children: [
                  // 曲线连线
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _EqCurvePainter(values, accent),
                    ),
                  ),
                  // 滑块
                  Row(
                    children: List.generate(values.length, (i) {
                  return Expanded(
                    child: Column(
                      children: [
                        // dB 值
                        Text(
                          '${values[i] >= 0 ? '+' : ''}${values[i].toStringAsFixed(1)}',
                          style: WlText.mono(
                            fontSize: 9,
                            height: 1.1,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        // 竖滑块
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3, // 竖直方向
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                activeTrackColor: accent,
                                inactiveTrackColor: AppTheme.s4
                                    .withValues(alpha: 0.5),
                                overlayColor: accent.withValues(alpha: 0.1),
                              ),
                              child: Slider(
                                value: values[i].clamp(-12.0, 12.0),
                                min: -12,
                                max: 12,
                                divisions: 48,
                                onChanged: (v) => dsp.setEqBand(i, v),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        // 频率标签
                        Text(
                          _bandLabel(freqs[i]),
                          style: WlText.mono(
                            fontSize: 9,
                            height: 1.1,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  );
                    }),
                  ),
                ],
              ),
            ),
          ),
        const Divider(height: 1, color: AppTheme.divider),
      ],
    );
  }
}

/// EQ 曲线连线：把 10 个频段的 dB 值用平滑曲线连起来
class _EqCurvePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  _EqCurvePainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final stepX = size.width / (values.length - 1);
    final midY = size.height / 2;
    final scaleY = (size.height / 2) / 12.0;

    // 构建路径
    final path = Path();
    final points = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = midY - values[i] * scaleY;
      points.add(Offset(x, y));
    }

    // 用贝塞尔曲线连接
    path.moveTo(points[0].dx, points[0].dy);
    for (int i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final curr = points[i];
      final midX = (prev.dx + curr.dx) / 2;
      path.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
    }

    // 绘制曲线
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 绘制中线（0 dB 参考）
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = AppTheme.divider
        ..strokeWidth = 0.5,
    );
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter old) =>
      values != old.values || color != old.color;
}

// ── DSP Effect Item ──

class _EffectItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool enabled;
  final VoidCallback onToggle;

  const _EffectItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          // 图标在图标区内垂直居中，与文字起点严格对齐
          SizedBox(
            width: 24,
            height: 24,
            child: Icon(icon, size: 20, color: AppTheme.textSecondary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  enabled ? '${l10n.enabled} · $subtitle' : subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          _Toggle(value: enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      // 对齐 label 文字起点：20(左距) + 24(图标区) + 14(间距)
      indent: 58,
      color: AppTheme.textTertiary.withValues(alpha: 0.15),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final VoidCallback onChanged;

  const _Toggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return SizedBox(
      width: 44,
      height: 24,
      child: GestureDetector(
        onTap: onChanged,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: value
                ? accent
                : AppTheme.textTertiary.withValues(alpha: 0.3),
          ),
          padding: const EdgeInsets.all(2),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
