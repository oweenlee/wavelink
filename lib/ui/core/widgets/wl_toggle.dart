import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 全 App 统一的开关组件：强调色胶囊底 + 白色圆钮（AccentScope 取色）。
/// 音效面板与设置页共用，保证开关视觉一致；非播放域自动回退 accentFallback。
class WlToggle extends StatelessWidget {
  final bool value;
  final VoidCallback onChanged;

  const WlToggle({super.key, required this.value, required this.onChanged});

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
