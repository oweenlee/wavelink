import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      children: [
        _Section(
          title: '音频',
          children: [
            _SettingItem(
              icon: Icons.tune_rounded,
              label: 'DSP 管线配置',
              onTap: () {},
            ),
            _SettingItem(
              icon: Icons.equalizer_rounded,
              label: '均衡器 (10段 PEQ)',
              onTap: () {},
            ),
            _SettingItem(
              icon: Icons.graphic_eq_rounded,
              label: 'Crossfeed',
              onTap: () {},
            ),
            _SettingItem(
              icon: Icons.volume_up_rounded,
              label: '输出设备',
              onTap: () {},
            ),
            _SwitchItem(
              icon: Icons.auto_awesome_rounded,
              label: 'ReplayGain',
              value: true,
              onChanged: (_) {},
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: '外观',
          children: [
            _SettingItem(
              icon: Icons.palette_rounded,
              label: '主题',
              trailing: '深色',
              onTap: () {},
            ),
            _SwitchItem(
              icon: Icons.colorize_rounded,
              label: '动态取色',
              value: true,
              onChanged: (_) {},
            ),
            _SliderItem(
              icon: Icons.blur_on_rounded,
              label: '封面模糊强度',
              value: 0.7,
              onChanged: (_) {},
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: '曲库',
          children: [
            _SettingItem(
              icon: Icons.folder_rounded,
              label: '扫描目录',
              onTap: () {},
            ),
            _ActionItem(
              icon: Icons.refresh_rounded,
              label: '重新扫描曲库',
              onTap: () {},
            ),
            _SettingItem(
              icon: Icons.file_upload_outlined,
              label: '导入/导出播放列表',
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: '关于',
          children: [
            _SettingItem(
              icon: Icons.info_outline_rounded,
              label: '版本',
              trailing: 'v0.1.0',
              onTap: () {},
            ),
            _SettingItem(icon: Icons.code_rounded, label: '开源许可', onTap: () {}),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceDark.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: children.asMap().entries.map((entry) {
                return Column(
                  children: [
                    if (entry.key > 0) const Divider(height: 1, indent: 52),
                    entry.value,
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback onTap;

  const _SettingItem({
    required this.icon,
    required this.label,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.textSecondary, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      ),
      trailing: trailing != null
          ? Text(
              trailing!,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textTertiary,
              ),
            )
          : const Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.textTertiary,
              size: 20,
            ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

class _SwitchItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.textSecondary, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppTheme.accentBlue,
      ),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.textPrimary,
                  ),
                ),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: AppTheme.accentBlue,
                    inactiveTrackColor: AppTheme.textTertiary.withValues(
                      alpha: 0.3,
                    ),
                    thumbColor: AppTheme.accentBlue,
                    overlayColor: AppTheme.accentBlue.withValues(alpha: 0.1),
                  ),
                  child: Slider(value: value, onChanged: onChanged),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.accentBlue, size: 22),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppTheme.accentBlue),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}
