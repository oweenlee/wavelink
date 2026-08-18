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
/// 设计遵循桌面端灰阶哲学（无彩色强调），技术读数用等宽 [WlText.mono]。
/// 音频命令直接走 [Engine] 服务（[PlayerController.engine]），不引入 riverpod
/// repository 抽象，保持与 mobile 解耦、移动端零回归。
class SettingsScreen extends ConsumerStatefulWidget {
  final PlayerController player;
  const SettingsScreen({super.key, required this.player});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Engine? get engine => widget.player.engine;

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

  Widget _sectionTitle(String t, {Key? key}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(
          t,
          key: key,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      );

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
    final mode = ref.watch(localeProvider);
    final engineNull = engine == null;
    return Scaffold(
      backgroundColor: AppTheme.s1,
      appBar: AppBar(
        title: const Text('设置',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft,
              size: 18, color: AppTheme.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _sectionTitle('通用', key: const Key('sec_general')),
          _card(children: [
            _row(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('语言',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
                                      color: AppTheme.textPrimary,
                                      fontSize: 13)),
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
            _row(SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _confirmClearAll(context),
                icon: const Icon(LucideIcons.trash2, size: 16),
                label: const Text('清空所有数据'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.highlightStrong),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            )),
          ]),
          if (engineNull)
            _row(const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '音频引擎未加载（缺少动态库），DSP / 设备设置不可用。',
                style:
                    TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              ),
            )),

          // ── 音频输出 ──
          _sectionTitle('音频输出', key: const Key('sec_audio')),
          _card(children: [
            _row(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('输出设备',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
            _row(_divider()),
            _row(Text(
              '状态：设备「${_selectedDevice ?? '系统默认'}」 · '
              '${_exclusive ? '独占' : '共享'} · '
              '${_actualSr != null ? '$_actualSr Hz' : '—'}',
              style: WlText.mono(color: AppTheme.textSecondary),
            )),
            if (Platform.isWindows)
              _row(_switchRow(
                'WASAPI 独占模式（切换将重启引擎）',
                _exclusive,
                (v) async {
                  setState(() => _exclusive = v);
                  final messenger = ScaffoldMessenger.of(context);
                  final err = await engine?.reinitialize(exclusiveMode: v);
                  if (err != null && mounted) {
                    messenger.showSnackBar(SnackBar(
                        content: Text('独占模式切换失败：$err')));
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
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
                            borderSide: BorderSide(
                                color: AppTheme.highlightStrong),
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
          ]),

          // ── DSP 效果 ──
          _sectionTitle('DSP 效果', key: const Key('sec_dsp')),
          _card(children: [
            _row(_switchRow('立体声展宽', _widenerOn, (v) {
              setState(() => _widenerOn = v);
              engine?.setStereoWidener(v, _widenerWidth);
            })),
            _row(Slider(
              value: _widenerWidth,
              min: 0,
              max: 1,
              label: '展宽',
              onChanged: (v) {
                setState(() => _widenerWidth = v);
                if (_widenerOn) engine?.setStereoWidener(true, v);
              },
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
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
                                      color: AppTheme.textPrimary,
                                      fontSize: 13)),
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
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
                            borderSide: BorderSide(
                                color: AppTheme.highlightStrong),
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
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _irPath.isEmpty
                            ? '未载入'
                            : _irPath.split('/').last,
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
          ]),

          // ── 诊断 ──
          _sectionTitle('诊断', key: const Key('sec_diag')),
          _card(children: [
            _row(Text('Underrun 计数：$_underrun',
                style: WlText.mono(color: AppTheme.textSecondary))),
            _row(Text(
                '最后错误：${_lastError.isEmpty ? '无' : _lastError}',
                style: WlText.mono(color: AppTheme.textSecondary))),
            _row(Text(
                '当前曲目：${_currentPath.isEmpty ? '—' : _currentPath}',
                style: WlText.mono(color: AppTheme.textSecondary))),
            _row(OutlinedButton(
              onPressed: () => _refreshDiagnostic(),
              child: const Text('刷新'),
            )),
          ]),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
