import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../services/engine.dart';
import '../services/locale_provider.dart';
import '../services/player_controller.dart';

/// 设置页（桌面补齐）：语言 / 数据管理 + 音频输出 / DSP / 诊断。
///
/// 布局采用桌面音乐 app 常见的「左侧导航 + 右侧内容」主从结构（对齐 Tidal /
/// Foobar2000 / Roon 范式），而非单列长滚动。设计遵循桌面端灰阶哲学
/// （无彩色强调），技术读数用等宽 [WlText.mono]。
/// 音频命令直接走 [Engine] 服务（[PlayerController.engine]），不引入 riverpod
/// repository 抽象，保持与 mobile 解耦、移动端零回归。
class SettingsScreen extends ConsumerStatefulWidget {
  final PlayerController player;
  const SettingsScreen({super.key, required this.player});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

/// 导航分类元信息（图标 + 标题 + 副标题 + 测试 Key 前缀）。
class _SectionMeta {
  final String key;
  final String title;
  final IconData icon;
  final String subtitle;
  const _SectionMeta(this.key, this.title, this.icon, this.subtitle);
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Engine? get engine => widget.player.engine;

  /// 分类顺序即导航栏顺序；[key] 同时用作内容标题 Key 前缀（`sec_<key>`）。
  static const List<_SectionMeta> _sections = [
    _SectionMeta('general', '通用', LucideIcons.settings, '语言与数据管理'),
    _SectionMeta('audio', '音频输出', LucideIcons.volume2, '设备选择与引擎状态'),
    _SectionMeta('dsp', 'DSP 效果', LucideIcons.slidersHorizontal, '实时音频处理链'),
    _SectionMeta('diag', '诊断', LucideIcons.activity, '引擎运行指标'),
  ];

  int _active = 0;

  final List<String> _locales = const ['system', 'zh', 'ja', 'de', 'en'];
  final Map<String, String> _localeLabels = const {
    'system': '跟随系统',
    'zh': '简体中文',
    'ja': '日本語',
    'de': 'Deutsch',
    'en': 'English',
  };

  List<String> _devices = [];
  String? _selectedDevice;
  bool _exclusive = false;
  int? _actualSr;

  // ── DSP 状态 ──
  bool _widenerOn = false;
  double _widenerWidth = 0.5;
  bool _crossfeed = false;
  bool _limiter = false;
  bool _dither = false;
  bool _noiseShaping = false;
  double _gain = 0;
  double _speed = 1.0;
  String _autoEq = '';
  String _preset = 'flat';
  String _irPath = '';

  // ── 诊断 ──
  int _underrun = 0;
  String _lastError = '';
  String _currentPath = '';

  final _srController = TextEditingController(text: '44100');

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _refreshDiagnostic();
    _refreshSr();
  }

  @override
  void dispose() {
    _srController.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      _devices = await engine?.enumerateDevices() ?? [];
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _refreshDiagnostic() async {
    final e = engine;
    if (e == null) return;
    _underrun = await e.underrunCount();
    _lastError = await e.lastError();
    _currentPath = await e.currentPath();
    if (mounted) setState(() {});
  }

  Future<void> _refreshSr() async {
    final e = engine;
    if (e == null) return;
    _actualSr = await e.outputSampleRate();
    if (mounted) setState(() {});
  }

  // ── 通用卡片基元 ──
  Widget _card({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: AppTheme.s2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(children: children),
      );

  Widget _row(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: child,
      );

  Widget _divider() =>
      const Divider(height: 1, thickness: 1, color: AppTheme.divider);

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged,
          {Key? key}) =>
      Row(
        key: key ?? Key('sw_$label'),
        children: [
          Expanded(
            child: Text(label,
                style:
                    const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      );

  /// 技术读数 chip：label 用三级灰，value 用一级灰（等宽）。
  Widget _chip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.s3,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                  text: '$label ', style: WlText.mono(color: AppTheme.textTertiary)),
              TextSpan(
                  text: value, style: WlText.mono(color: AppTheme.textPrimary)),
            ],
          ),
        ),
      );

  Widget _chips(List<Widget> children) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: children,
      );

  Future<void> _pickIr() async {
    final x = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'IR', extensions: ['wav']),
      ],
    );
    if (x != null) {
      await engine?.loadIr(x.path);
      if (mounted) setState(() => _irPath = x.path);
    }
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.s2,
        title: const Text('清空所有数据',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('将删除全部曲库、收藏与播放列表，且不可恢复。',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.player.clearAllData();
      if (mounted) {
        messenger
            .showSnackBar(const SnackBar(content: Text('已清空所有数据')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final engineNull = engine == null;
    return Scaffold(
      backgroundColor: AppTheme.s1,
      body: Row(
        children: [
          _SettingsRail(
            activeIndex: _active,
            onSelect: (i) => setState(() => _active = i),
          ),
          Expanded(child: _sectionContent(engineNull)),
        ],
      ),
    );
  }

  Widget _sectionContent(bool engineNull) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(_sections[_active]),
                  const SizedBox(height: 16),
                  if (engineNull) _engineNullBanner(),
                  _activeContent(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _sectionHeader(_SectionMeta m) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(m.icon, size: 20, color: AppTheme.textPrimary),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.title,
                  key: Key('sec_${m.key}'),
                  style: const TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      color: AppTheme.textPrimary,
                      letterSpacing: -0.3)),
              const SizedBox(height: 2),
              Text(m.subtitle,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
        ],
      );

  Widget _engineNullBanner() => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.s3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: const Row(
          children: [
            Icon(LucideIcons.alertCircle, size: 16, color: AppTheme.textTertiary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '音频引擎未加载（缺少动态库），DSP / 设备设置不可用。',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      );

  Widget _activeContent() {
    switch (_active) {
      case 0:
        return _buildGeneral();
      case 1:
        return _buildAudio();
      case 2:
        return _buildDsp();
      default:
        return _buildDiag();
    }
  }

  // ── 通用 ──
  Widget _buildGeneral() {
    final mode = ref.watch(localeProvider);
    return _card(children: [
      _row(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('语言',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppTheme.s3,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.highlightStrong),
            ),
            child: DropdownButton<String>(
              value: mode,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              icon: const Icon(LucideIcons.chevronDown,
                  size: 16, color: AppTheme.textSecondary),
              items: _locales
                  .map((k) => DropdownMenuItem(
                        value: k,
                        child: Text(_localeLabels[k]!,
                            style: const TextStyle(
                                color: AppTheme.textPrimary, fontSize: 13)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(localeProvider.notifier).setMode(v);
                }
              },
            ),
          ),
        ],
      )),
      _row(_divider()),
      _row(Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: () => _confirmClearAll(context),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.danger,
              side: const BorderSide(color: AppTheme.danger),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('清空所有数据'),
          ),
        ],
      )),
    ]);
  }

  // ── 音频输出 ──
  Widget _buildAudio() => _card(children: [
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输出设备',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppTheme.s3,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.highlightStrong),
              ),
              child: DropdownButton<String?>(
                value: _selectedDevice,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                hint: const Text('系统默认',
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 13)),
                icon: const Icon(LucideIcons.chevronDown,
                    size: 16, color: AppTheme.textSecondary),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('系统默认',
                        style: TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13)),
                  ),
                  ..._devices.map(
                    (d) => DropdownMenuItem<String?>(
                      value: d,
                      child: Text(d,
                          style: const TextStyle(
                              color: AppTheme.textPrimary, fontSize: 13)),
                    ),
                  ),
                ],
                onChanged: (v) async {
                  setState(() => _selectedDevice = v);
                  await engine?.setOutputDevice(v);
                },
              ),
            ),
          ],
        )),
        _row(_chips([
          _chip('设备', _selectedDevice ?? '系统默认'),
          _chip('模式', _exclusive ? '独占' : '共享'),
          _chip('采样率', _actualSr != null ? '$_actualSr Hz' : '—'),
        ])),
        if (Platform.isWindows)
          _row(_switchRow(
            'WASAPI 独占模式（切换将重启引擎）',
            _exclusive,
            (v) async {
              setState(() => _exclusive = v);
              final messenger = ScaffoldMessenger.of(context);
              final err = await engine?.reinitialize(exclusiveMode: v);
              if (err != null && mounted) {
                messenger.showSnackBar(
                    SnackBar(content: Text('独占模式切换失败：$err')));
              }
              _refreshSr();
            },
            key: const Key('sw_exclusive'),
          )),
        _row(_divider()),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输出采样率（Hz，下次播放生效）',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('sr_field'),
                    controller: _srController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      filled: true,
                      fillColor: AppTheme.s3,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: AppTheme.highlightStrong),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('sr_apply'),
                  onPressed: () {
                    final r = int.tryParse(_srController.text);
                    if (r != null) engine?.setOutputSampleRate(r);
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        )),
      ]);

  // ── DSP 效果 ──
  Widget _buildDsp() => _card(children: [
        _row(_switchRow('立体声展宽', _widenerOn, (v) {
          setState(() => _widenerOn = v);
          engine?.setStereoWidener(v, _widenerWidth);
        })),
        _row(Row(
          children: [
            Expanded(
              child: Slider(
                value: _widenerWidth,
                min: 0,
                max: 1,
                label: '展宽',
                onChanged: (v) {
                  setState(() => _widenerWidth = v);
                  if (_widenerOn) engine?.setStereoWidener(true, v);
                },
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(_widenerWidth.toStringAsFixed(2),
                  style: WlText.mono(color: AppTheme.textSecondary)),
            ),
          ],
        )),
        _row(_divider()),
        _row(_switchRow('跨馈 (Crossfeed)', _crossfeed, (v) {
          setState(() => _crossfeed = v);
          engine?.setCrossfeed(v);
        })),
        _row(_switchRow('真峰值限幅 (Limiter)', _limiter, (v) {
          setState(() => _limiter = v);
          engine?.setLimiter(v);
        })),
        _row(_switchRow('抖动 (Dither)', _dither, (v) {
          setState(() => _dither = v);
          engine?.setDither(v);
        })),
        _row(_switchRow('噪声整形 (Noise Shaping)', _noiseShaping, (v) {
          setState(() => _noiseShaping = v);
          engine?.setNoiseShaping(v);
        })),
        _row(_divider()),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ReplayGain 增益 (dB)',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _gain,
                    min: -12,
                    max: 12,
                    label: '增益',
                    onChanged: (v) {
                      setState(() => _gain = v);
                      engine?.setReplaygainGain(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(_gain.toStringAsFixed(1),
                      style: WlText.mono(color: AppTheme.textSecondary)),
                ),
              ],
            ),
          ],
        )),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('播放速度',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _speed,
                    min: 0.25,
                    max: 4,
                    label: '速度',
                    onChanged: (v) {
                      setState(() => _speed = v);
                      engine?.setSpeed(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text('${_speed.toStringAsFixed(2)}x',
                      style: WlText.mono(color: AppTheme.textSecondary)),
                ),
              ],
            ),
          ],
        )),
        _row(_divider()),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('EQ 预设',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppTheme.s3,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.highlightStrong),
              ),
              child: DropdownButton<String>(
                key: const Key('preset_dropdown'),
                value: _preset,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                icon: const Icon(LucideIcons.chevronDown,
                    size: 16, color: AppTheme.textSecondary),
                items: const [
                  'flat',
                  'rock',
                  'pop',
                  'dance',
                  'classical',
                  'soft',
                  'full_bass',
                  'full_treble',
                  'techno',
                  'vocals'
                ]
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text(p,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary, fontSize: 13)),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _preset = v);
                    engine?.applyPreset(v);
                  }
                },
              ),
            ),
          ],
        )),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AutoEQ 耳机型号（留空清除）',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => _autoEq = v,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      filled: true,
                      fillColor: AppTheme.s3,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: AppTheme.highlightStrong),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () =>
                      engine?.setAutoEq(_autoEq.isEmpty ? null : _autoEq),
                  child: const Text('应用'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    setState(() => _autoEq = '');
                    engine?.setAutoEq(null);
                  },
                  child: const Text('清除'),
                ),
              ],
            ),
          ],
        )),
        _row(_divider()),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('房间校正 FIR (REW → .wav)',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _irPath.isEmpty ? '未载入' : _irPath.split('/').last,
                    style: WlText.mono(color: AppTheme.textSecondary),
                  ),
                ),
                OutlinedButton(
                  onPressed: _pickIr,
                  child: const Text('载入'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('fir_clear'),
                  onPressed: () {
                    setState(() => _irPath = '');
                    engine?.clearIr();
                  },
                  child: const Text('清除'),
                ),
              ],
            ),
          ],
        )),
      ]);

  // ── 诊断 ──
  Widget _buildDiag() => _card(children: [
        _row(_chips([
          _chip('Underrun 计数', '$_underrun'),
          _chip('最后错误', _lastError.isEmpty ? '无' : _lastError),
        ])),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前曲目',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Text(
              _currentPath.isEmpty ? '—' : _currentPath,
              style: WlText.mono(color: AppTheme.textSecondary),
            ),
          ],
        )),
        _row(Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: () => _refreshDiagnostic(),
              child: const Text('刷新'),
            ),
          ],
        )),
      ]);
}

/// 设置页左侧导航栏：返回 + 品牌 + 4 个分类。
/// 视觉语言与 home 的 [_Sidebar]/[_NavItem] 对齐（s2 底、选中 s3 + 左侧白条）。
class _SettingsRail extends StatelessWidget {
  final int activeIndex;
  final ValueChanged<int> onSelect;
  const _SettingsRail(
      {required this.activeIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: AppTheme.s2,
        border: Border(right: BorderSide(color: AppTheme.highlightStrong)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 12, 10),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(LucideIcons.arrowLeft,
                      size: 18, color: AppTheme.textPrimary),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '返回',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                const SizedBox(width: 4),
                const Text('WaveLink',
                    style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppTheme.textPrimary,
                        letterSpacing: -0.3)),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppTheme.divider),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              itemCount: _SettingsScreenState._sections.length,
              itemBuilder: (c, i) {
                final m = _SettingsScreenState._sections[i];
                final active = i == activeIndex;
                return _RailItem(
                  key: Key('nav_${m.key}'),
                  icon: m.icon,
                  label: m.title,
                  active: active,
                  onTap: () => onSelect(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppTheme.s3 : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: active
              ? const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: AppTheme.textPrimary, width: 3),
                  ),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon,
                  size: 18,
                  color: active
                      ? AppTheme.textPrimary
                      : AppTheme.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: active
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
