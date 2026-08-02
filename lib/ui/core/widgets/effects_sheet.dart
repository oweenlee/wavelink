import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../features/playback/view_models/playback_provider.dart';
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
            const SizedBox(height: 8),
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

/// 10 段参量 EQ：竖滑块 + dB 值 + 预设 chips + 贝塞尔曲线连线
/// TODO: 接入 Rust 引擎的 EQ 模块，当前为 UI demo（本地状态）
class _EqSection extends StatefulWidget {
  @override
  State<_EqSection> createState() => _EqSectionState();
}

class _EqSectionState extends State<_EqSection> {
  // EQ 频段标签
  static const _bands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

  // 当前 EQ 值（dB），默认全 0
  List<double> _values = List.filled(10, 0.0);
  String _activePreset = 'Flat';

  // EQ 预设
  static const _presets = <String, List<double>>{
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Rock': [4.0, 3.0, 2.0, -1.0, -2.0, -1.0, 2.0, 4.0, 5.0, 5.0],
    'Pop': [-1.0, 1.0, 3.0, 4.0, 3.0, 0.0, -1.0, -1.0, 2.0, 3.0],
    'Dance': [5.0, 4.0, 1.0, 0.0, -2.0, -2.0, 0.0, 1.0, 3.0, 4.0],
    'Classical': [3.0, 2.0, 0.0, -1.0, -1.0, 0.0, 2.0, 3.0, 4.0, 4.0],
    'Soft': [2.0, 1.0, 0.0, 1.0, 2.0, 2.0, 1.0, 0.0, 0.0, -1.0],
    'Full Bass': [6.0, 5.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Full Treble': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 4.0, 5.0, 6.0],
    'Techno': [4.0, 3.0, 0.0, -2.0, -3.0, -1.0, 1.0, 3.0, 4.0, 5.0],
    'Vocals': [-2.0, -1.0, 0.0, 2.0, 4.0, 4.0, 3.0, 1.0, 0.0, -1.0],
  };

  void _applyPreset(String name) {
    setState(() {
      _activePreset = name;
      _values = List.from(_presets[name]!);
    });
    // TODO: player.applyEqPreset(name) — 接入引擎
  }

  void _setBand(int i, double v) {
    setState(() {
      _values[i] = v;
      _activePreset = ''; // 手动调整后取消预设高亮
    });
    // TODO: player.setEqBand(i, v) — 接入引擎
  }

  String _bandLabel(int hz) {
    if (hz >= 1000) return '${hz ~/ 1000}k';
    return '$hz';
  }

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // header + preset chips
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 0, 8),
          child: Row(
            children: [
              Text(
                'EQUALIZER',
                style: WlText.mono(
                  fontSize: 10,
                  color: AppTheme.textTertiary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
        ),
        // 预设 chips（水平可滚动）
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: _presets.keys.map((p) {
              final active = _activePreset == p;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => _applyPreset(p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
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
                        color: active
                            ? accent
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        // 10 条竖滑块 + 曲线
        SizedBox(
          height: 180,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Stack(
              children: [
                // 曲线连线
                Positioned.fill(
                  child: CustomPaint(
                    painter: _EqCurvePainter(_values, accent),
                  ),
                ),
                // 滑块
                Row(
                  children: List.generate(10, (i) {
                    return Expanded(
                      child: Column(
                        children: [
                          // dB 值
                          Text(
                            '${_values[i] >= 0 ? '+' : ''}${_values[i].toStringAsFixed(1)}',
                            style: WlText.mono(
                              fontSize: 8,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 2),
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
                                  value: _values[i].clamp(-12.0, 12.0),
                                  min: -12,
                                  max: 12,
                                  divisions: 48,
                                  onChanged: (v) => _setBand(i, v),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          // 频率标签
                          Text(
                            _bandLabel(_bands[i]),
                            style: WlText.mono(
                              fontSize: 8,
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled ? '${l10n.enabled} · $subtitle' : subtitle,
                  style: const TextStyle(
                    fontSize: 12,
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
      indent: 54,
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
