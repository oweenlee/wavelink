import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme.dart';
import '../services/engine.dart';
import '../services/locale_provider.dart';
import '../services/player_controller.dart';
import '../src/rust/api/room.dart' as frb_room;

/// 设置页（桌面补齐）：语言 / 数据管理 + 音频输出 / DSP / 诊断。
///
/// 布局「左侧导航 + 右侧内容」主从结构（Tidal / Roon 范式）。视觉延续灰阶
/// 哲学，但引入 [AccentScope] 强调色作交互焦点（导航选中、Switch/Slider、
/// 主按钮），并用语义色状态灯表达引擎健康度——控件层精致、信息层清晰。
///
/// 音频/DSP 设置与 [PlayerController.init] 的 `_restoreAudioSettings` 同源
/// 读写 SharedPreferences（启动恢复、即时落盘，「清空所有数据」一并清除）。
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
    _SectionMeta('audio', '音频输出', LucideIcons.volume2, '设备选择与采样率'),
    _SectionMeta('dsp', 'DSP 效果', LucideIcons.slidersHorizontal, '实时音频处理链'),
    _SectionMeta('diag', '诊断', LucideIcons.activity, '引擎运行指标'),
  ];

  int _active = 0;
  SharedPreferences? _prefs;
  Timer? _diagTimer;

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

  // ── 引擎高级配置 ──
  bool _bitPerfect = false;
  bool _autoSampleRate = false;
  double _crossfadeMs = 0;

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
    _loadPersistedState();
    // 诊断页周期自刷新（仅当激活时拉取，避免后台空转）
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_active == 3) _refreshDiagnostic();
    });
  }

  @override
  void dispose() {
    _diagTimer?.cancel();
    _srController.dispose();
    super.dispose();
  }

  /// 从 SharedPreferences 回显音频/DSP 设置（与引擎恢复同源，保证 UI 与
  /// 实际生效一致；prefs 读回是缓存实例，几乎瞬时）。
  Future<void> _loadPersistedState() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    if (!mounted) return;
    setState(() {
      _selectedDevice = p.getString('outputDevice');
      _exclusive = p.getBool('exclusiveMode') ?? false;
      _srController.text = (p.getInt('outputSampleRate') ?? 44100).toString();
      _widenerOn = p.getBool('dsp.widener') ?? false;
      _widenerWidth = p.getDouble('dsp.widenerWidth') ?? 0.5;
      _crossfeed = p.getBool('dsp.crossfeed') ?? false;
      _limiter = p.getBool('dsp.limiter') ?? false;
      _dither = p.getBool('dsp.dither') ?? false;
      _noiseShaping = p.getBool('dsp.noiseShaping') ?? false;
      _gain = p.getDouble('dsp.gain') ?? 0;
      _speed = p.getDouble('dsp.speed') ?? 1.0;
      _preset = p.getString('dsp.preset') ?? 'flat';
      _autoEq = p.getString('dsp.autoEq') ?? '';
      _irPath = p.getString('dsp.irPath') ?? '';
      _bitPerfect = p.getBool('engine.bitPerfect') ?? false;
      _autoSampleRate = p.getBool('engine.autoSampleRate') ?? false;
      _crossfadeMs = (p.getInt('engine.crossfadeMs') ?? 0).toDouble();
    });
    _refreshSr();
  }

  // ── 即时落盘（fire-and-forget，与启动恢复同 key） ──
  void _saveBool(String k, bool v) => unawaited(_prefs?.setBool(k, v));
  void _saveDouble(String k, double v) => unawaited(_prefs?.setDouble(k, v));
  void _saveInt(String k, int v) => unawaited(_prefs?.setInt(k, v));
  void _saveString(String k, String? v) {
    if (v == null) {
      unawaited(_prefs?.remove(k));
    } else {
      unawaited(_prefs?.setString(k, v));
    }
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
    final u = await e.underrunCount();
    final l = await e.lastError();
    final c = await e.currentPath();
    if (!mounted) return;
    setState(() {
      _underrun = u;
      _lastError = l;
      _currentPath = c;
    });
  }

  Future<void> _refreshSr() async {
    final e = engine;
    if (e == null) return;
    _actualSr = await e.outputSampleRate();
    if (mounted) setState(() {});
  }

  // ───────────────────────── 页面骨架 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    final engineNull = engine == null;
    return Scaffold(
      backgroundColor: AppTheme.s1,
      body: Row(
        children: [
          _SettingsRail(
            activeIndex: _active,
            engineReady: !engineNull,
            onSelect: (i) => setState(() => _active = i),
          ),
          Expanded(
            child: _SectionContent(
              section: _sections[_active],
              engineNull: engineNull,
              accent: accent,
              child: _activeContent(),
            ),
          ),
        ],
      ),
    );
  }

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

  // ───────────────────────── 控件基元 ─────────────────────────

  /// 卡片：圆角 + 边框 + 微弱投影（投影保留「浮起」感，桌面端克制使用）。
  Widget _card({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: AppTheme.s2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.highlightStrong),
          boxShadow: const [
            BoxShadow(
                color: Color(0x33000000),
                blurRadius: 16,
                offset: Offset(0, 6)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _row(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: child,
      );

  Widget _divider() =>
      const Divider(height: 1, thickness: 1, color: AppTheme.divider);

  /// 分组标题：大写 + 字距 + 前置短横（细分卡片内语义区）。
  Widget _groupLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 12,
              decoration: BoxDecoration(
                color: AppTheme.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(t.toUpperCase(),
                style: const TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _fieldLabel(String t) => Text(t,
      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12));

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged,
          {Key? key, Color? accent}) =>
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
            activeThumbColor: (accent ?? AppTheme.textPrimary).withAlpha(255),
            activeTrackColor:
                (accent ?? AppTheme.textPrimary).withAlpha(0x30),
            inactiveThumbColor: AppTheme.textTertiary,
            inactiveTrackColor: AppTheme.s3,
          ),
        ],
      );

  /// 技术读数 chip：label 三级灰、value 等宽一级灰。
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
                  text: '$label ',
                  style: WlText.mono(color: AppTheme.textTertiary)),
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

  /// 统一输入框：s3 填充、圆角、focus 强调色。
  Widget _field({
    Key? key,
    TextEditingController? controller,
    String? hint,
    void Function(String)? onChanged,
    Color? accent,
  }) =>
      TextField(
        key: key,
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              const TextStyle(color: AppTheme.textTertiary, fontSize: 13),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          filled: true,
          fillColor: AppTheme.s3,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppTheme.highlightStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
                color: accent ?? AppTheme.textTertiary, width: 1.4),
          ),
        ),
      );

  /// 统一下拉框：s3 底、圆角、无下划线。
  Widget _dropdown<T>({
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    String? hint,
    Key? key,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.s3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: DropdownButton<T>(
          key: key,
          value: value,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          icon: const Icon(LucideIcons.chevronDown,
              size: 16, color: AppTheme.textSecondary),
          hint: hint != null
              ? Text(hint,
                  style: const TextStyle(
                      color: AppTheme.textTertiary, fontSize: 13))
              : null,
          items: items,
          onChanged: onChanged,
        ),
      );

  /// 统一滑块行：label + 强调色 Slider + 等宽读数。
  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required String Function(double) fmt,
    required ValueChanged<double> onChanged,
    Color? accent,
  }) =>
      _row(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(label),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    thumbColor: accent ?? AppTheme.textPrimary,
                    activeTrackColor: accent ?? AppTheme.textPrimary,
                    inactiveTrackColor: AppTheme.s4,
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(fmt(value),
                    textAlign: TextAlign.end,
                    style: WlText.mono(color: AppTheme.textSecondary)),
              ),
            ],
          ),
        ],
      ));

  /// 实心主按钮（强调色底 + 对比文字）。
  Widget _primaryBtn({
    Key? key,
    required String label,
    required VoidCallback onPressed,
    Color? accent,
  }) =>
      FilledButton(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: accent ?? AppTheme.textPrimary,
          foregroundColor: (accent ?? AppTheme.textPrimary).computeLuminance() >
                  0.45
              ? AppTheme.background
              : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle:
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      );

  // ───────────────────────── 通用 ─────────────────────────

  Widget _buildGeneral() {
    final mode = ref.watch(localeProvider);
    return _card(children: [
      _groupLabel('语言'),
      _row(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel('界面语言'),
          const SizedBox(height: 6),
          _dropdown<String>(
            value: mode,
            onChanged: (v) {
              if (v != null) {
                ref.read(localeProvider.notifier).setMode(v);
              }
            },
            items: _locales
                .map((k) => DropdownMenuItem(
                      value: k,
                      child: Text(_localeLabels[k]!,
                          style: const TextStyle(
                              color: AppTheme.textPrimary, fontSize: 13)),
                    ))
                .toList(),
          ),
        ],
      )),
      _row(_divider()),
      _groupLabel('数据'),
      _row(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.database,
                  size: 16, color: AppTheme.textTertiary),
              SizedBox(width: 8),
              Expanded(
                child: Text('删除全部曲库、收藏与播放列表（不可恢复）',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _confirmClearAll(context),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.danger,
              side: const BorderSide(color: AppTheme.danger),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(LucideIcons.trash2, size: 15),
            label: const Text('清空所有数据'),
          ),
        ],
      )),
    ]);
  }

  // ───────────────────────── 音频输出 ─────────────────────────

  Widget _buildAudio() => _card(children: [
        _groupLabel('输出设备'),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('设备'),
            const SizedBox(height: 6),
            _dropdown<String?>(
              value: _selectedDevice,
              hint: '系统默认',
              onChanged: (v) async {
                setState(() {
                  _selectedDevice = v;
                  _saveString('outputDevice', v);
                });
                await engine?.setOutputDevice(v);
              },
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
            ),
          ],
        )),
        _row(_chips([
          _chip('设备', _selectedDevice ?? '系统默认'),
          _chip('模式', _exclusive ? '独占' : '共享'),
          _chip('采样率', _actualSr != null ? '$_actualSr Hz' : '—'),
        ])),
        if (Platform.isWindows || Platform.isMacOS)
          _row(_switchRow(
            Platform.isWindows
                ? 'WASAPI 独占模式（切换将重启引擎）'
                : 'Hog Mode（独占音频设备，切换将重启引擎）',
            _exclusive,
            (v) async {
              setState(() {
                _exclusive = v;
                _saveBool('exclusiveMode', v);
              });
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
        _groupLabel('采样率'),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('输出采样率（Hz，下次播放生效）'),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _field(
                    key: const Key('sr_field'),
                    controller: _srController,
                    hint: '44100',
                  ),
                ),
                const SizedBox(width: 8),
                _primaryBtn(
                  key: const Key('sr_apply'),
                  label: '应用',
                  onPressed: () {
                    final r = int.tryParse(_srController.text);
                    if (r != null) {
                      engine?.setOutputSampleRate(r);
                      _saveInt('outputSampleRate', r);
                      _refreshSr();
                    }
                  },
                ),
              ],
            ),
          ],
        )),
        _row(_divider()),
        _groupLabel('高级'),
        _row(_switchRow('Bit-Perfect 直通（绕过 SRC 与 DSP）', _bitPerfect, (v) {
          setState(() {
            _bitPerfect = v;
            _saveBool('engine.bitPerfect', v);
          });
          // 启动参数，下次启动生效
        }, key: const Key('sw_bitperfect'))),
        _row(_switchRow('自动采样率（按源文件切换输出）', _autoSampleRate, (v) {
          setState(() {
            _autoSampleRate = v;
            _saveBool('engine.autoSampleRate', v);
          });
        }, key: const Key('sw_autosr'))),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('曲间无缝 Crossfade（下次启动生效）'),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      thumbColor: AppTheme.textPrimary,
                      activeTrackColor: AppTheme.textPrimary,
                      inactiveTrackColor: AppTheme.s4,
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      value: _crossfadeMs,
                      min: 0,
                      max: 8000,
                      divisions: 32,
                      onChanged: (v) {
                        setState(() {
                          _crossfadeMs = v;
                          _saveInt('engine.crossfadeMs', v.round());
                        });
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                      _crossfadeMs == 0
                          ? '关闭'
                          : '${_crossfadeMs.round()} ms',
                      textAlign: TextAlign.end,
                      style: WlText.mono(color: AppTheme.textSecondary)),
                ),
              ],
            ),
          ],
        )),
      ]);

  // ───────────────────────── DSP 效果 ─────────────────────────

  Widget _buildDsp() => _card(children: [
        _groupLabel('空间效果'),
        _row(_switchRow('立体声展宽', _widenerOn, (v) {
          setState(() {
            _widenerOn = v;
            _saveBool('dsp.widener', v);
          });
          engine?.setStereoWidener(v, _widenerWidth);
        })),
        _sliderRow(
          label: '展宽宽度',
          value: _widenerWidth,
          min: 0,
          max: 1,
          fmt: (v) => v.toStringAsFixed(2),
          onChanged: (v) {
            setState(() {
              _widenerWidth = v;
              _saveDouble('dsp.widenerWidth', v);
            });
            if (_widenerOn) engine?.setStereoWidener(true, v);
          },
        ),
        _row(_switchRow('跨馈 (Crossfeed)', _crossfeed, (v) {
          setState(() {
            _crossfeed = v;
            _saveBool('dsp.crossfeed', v);
          });
          engine?.setCrossfeed(v);
        })),
        _row(_divider()),
        _groupLabel('动态处理'),
        _row(_switchRow('真峰值限幅 (Limiter)', _limiter, (v) {
          setState(() {
            _limiter = v;
            _saveBool('dsp.limiter', v);
          });
          engine?.setLimiter(v);
        })),
        _row(_switchRow('抖动 (Dither)', _dither, (v) {
          setState(() {
            _dither = v;
            _saveBool('dsp.dither', v);
          });
          engine?.setDither(v);
        })),
        _row(_switchRow('噪声整形 (Noise Shaping)', _noiseShaping, (v) {
          setState(() {
            _noiseShaping = v;
            _saveBool('dsp.noiseShaping', v);
          });
          engine?.setNoiseShaping(v);
        })),
        _row(_divider()),
        _groupLabel('增益与速度'),
        _sliderRow(
          label: 'ReplayGain 增益 (dB)',
          value: _gain,
          min: -12,
          max: 12,
          fmt: (v) => v.toStringAsFixed(1),
          onChanged: (v) {
            setState(() {
              _gain = v;
              _saveDouble('dsp.gain', v);
            });
            engine?.setReplaygainGain(v);
          },
        ),
        _sliderRow(
          label: '播放速度',
          value: _speed,
          min: 0.25,
          max: 4,
          fmt: (v) => '${v.toStringAsFixed(2)}x',
          onChanged: (v) {
            setState(() {
              _speed = v;
              _saveDouble('dsp.speed', v);
            });
            engine?.setSpeed(v);
          },
        ),
        _row(_divider()),
        _groupLabel('均衡器'),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('EQ 预设'),
            const SizedBox(height: 6),
            _dropdown<String>(
              key: const Key('preset_dropdown'),
              value: _preset,
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _preset = v;
                    _saveString('dsp.preset', v);
                  });
                  engine?.applyPreset(v);
                }
              },
              items: const [
                'flat', 'rock', 'pop', 'dance', 'classical', 'soft',
                'full_bass', 'full_treble', 'techno', 'vocals'
              ]
                  .map((p) => DropdownMenuItem(
                        value: p,
                        child: Text(p,
                            style: const TextStyle(
                                color: AppTheme.textPrimary, fontSize: 13)),
                      ))
                  .toList(),
            ),
          ],
        )),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('AutoEQ 耳机型号'),
            const SizedBox(height: 6),
            InkWell(
              key: const Key('autoeq_picker'),
              onTap: _pickAutoEq,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.s3,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.highlightStrong),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _autoEq.isEmpty ? '关闭 AutoEQ' : _autoEq,
                        style: TextStyle(
                            color: _autoEq.isEmpty
                                ? AppTheme.textTertiary
                                : AppTheme.textPrimary,
                            fontSize: 13),
                      ),
                    ),
                    const Icon(LucideIcons.chevronDown,
                        size: 16, color: AppTheme.textSecondary),
                  ],
                ),
              ),
            ),
          ],
        )),
        _row(_divider()),
        _groupLabel('房间校正'),
        _row(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel('FIR 脉冲响应 (REW → .wav)'),
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
                    setState(() {
                      _irPath = '';
                      _saveString('dsp.irPath', null);
                    });
                    engine?.clearIr();
                  },
                  child: const Text('清除'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _divider(),
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text('从 REW 测量曲线生成校正 IR（.txt 频响导出）',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ),
                OutlinedButton.icon(
                  onPressed: _generateRew,
                  icon: const Icon(LucideIcons.wand2,
                      size: 15, color: AppTheme.textSecondary),
                  label: const Text('生成'),
                ),
              ],
            ),
          ],
        )),
      ]);

  // ───────────────────────── 诊断 ─────────────────────────

  Widget _buildDiag() {
    final engineReady = engine != null;
    return Column(
      children: [
        _metricRow(engineReady),
        const SizedBox(height: 12),
        _card(children: [
          _row(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel('当前曲目'),
              const SizedBox(height: 6),
              Text(
                _currentPath.isEmpty ? '—' : _currentPath,
                style: WlText.mono(color: AppTheme.textSecondary),
              ),
            ],
          )),
          _row(_divider()),
          _row(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel('最后错误'),
              const SizedBox(height: 6),
              Text(
                _lastError.isEmpty ? '无' : _lastError,
                style: WlText.mono(
                    color: _lastError.isEmpty
                        ? AppTheme.textTertiary
                        : AppTheme.warn),
              ),
            ],
          )),
          _row(_divider()),
          _row(Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.refreshCw,
                      size: 14, color: AppTheme.textTertiary),
                  SizedBox(width: 6),
                  Text('每 2 秒自动刷新',
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 11)),
                ],
              ),
              OutlinedButton.icon(
                onPressed: () => _refreshDiagnostic(),
                icon: const Icon(LucideIcons.rotateCw,
                    size: 15, color: AppTheme.textSecondary),
                label: const Text('立即刷新'),
              ),
            ],
          )),
        ]),
      ],
    );
  }

  /// 三个指标卡：Underrun 计数 / 采样率 / 引擎状态。
  Widget _metricRow(bool engineReady) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metricCard(
            icon: LucideIcons.gauge,
            label: 'UNDERRUN',
            value: '$_underrun',
          ),
          const SizedBox(width: 12),
          _metricCard(
            icon: LucideIcons.waves,
            label: '采样率',
            value: _actualSr != null ? '$_actualSr Hz' : '—',
          ),
          const SizedBox(width: 12),
          _metricCard(
            icon: engineReady ? LucideIcons.circleCheck : LucideIcons.circleAlert,
            label: '引擎状态',
            value: engineReady ? '就绪' : '未加载',
            valueColor:
                engineReady ? AppTheme.ok : AppTheme.warn,
          ),
        ],
      );

  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: AppTheme.s2,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.highlightStrong),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 16,
                  offset: Offset(0, 6)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: valueColor ?? AppTheme.textTertiary),
              const SizedBox(height: 10),
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(value,
                  style: WlText.mono(
                      fontSize: 17,
                      color: valueColor ?? AppTheme.textPrimary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );

  Future<void> _pickIr() async {
    final x = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'IR', extensions: ['wav']),
      ],
    );
    if (x != null) {
      await engine?.loadIr(x.path);
      if (mounted) {
        setState(() {
          _irPath = x.path;
          _saveString('dsp.irPath', x.path);
        });
      }
    }
  }

  /// AutoEQ 型号选择（对齐 mobile）：弹 catalog 列表，含顶部「关闭」项。
  Future<void> _pickAutoEq() async {
    final accent = AccentScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final catalog = await engine?.autoEqCatalog() ?? const <String>[];
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.s2,
        title: const Text('AutoEQ 耳机型号',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
        content: SizedBox(
          width: 380,
          height: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              _AutoEqTile(
                label: '关闭 AutoEQ',
                selected: _autoEq.isEmpty,
                accent: accent,
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _autoEq = '';
                    _saveString('dsp.autoEq', null);
                  });
                  engine?.setAutoEq(null);
                },
              ),
              ...catalog.map((m) => _AutoEqTile(
                    label: m,
                    selected: m == _autoEq,
                    accent: accent,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      setState(() {
                        _autoEq = m;
                        _saveString('dsp.autoEq', m);
                      });
                      engine?.setAutoEq(m);
                    },
                  )),
            ],
          ),
        ),
      ),
    );
    if (mounted && _autoEq.isNotEmpty) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('已应用 AutoEQ：$_autoEq')));
    }
  }

  /// 从 REW 频响测量文本生成校正 FIR：解析 → core 生成系数 → 存临时 WAV → 加载。
  Future<void> _generateRew() async {
    final messenger = ScaffoldMessenger.of(context);
    final x = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'REW 测量', extensions: ['txt']),
      ],
    );
    if (x == null || !mounted) return;
    try {
      final text = await File(x.path).readAsString();
      final pts = await frb_room.parseRewText(text: text);
      if (pts.isEmpty) {
        messenger.showSnackBar(
            const SnackBar(content: Text('REW 文件解析失败：无有效测量点')));
        return;
      }
      final config = await frb_room.defaultCorrectionConfig();
      final sr = _actualSr ?? 44100;
      final result = await frb_room.generateRoomCorrection(
        rewTxt: text,
        config: config,
        sampleRate: sr,
      );
      final irFile = File(
          '${Directory.systemTemp.path}/wavelink_correction_${DateTime.now().millisecondsSinceEpoch}.wav');
      await frb_room.saveIrWav(
          ir: result.ir, sampleRate: sr, path: irFile.path);
      await engine?.loadIr(irFile.path);
      if (!mounted) return;
      setState(() {
        _irPath = irFile.path;
        _saveString('dsp.irPath', irFile.path);
      });
      messenger.showSnackBar(SnackBar(
        content: Text(
            '已生成校正 IR（${result.points} 点测量，${result.appliedGainDb.toStringAsFixed(1)} dB）'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('生成失败：$e')));
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
        messenger.showSnackBar(const SnackBar(content: Text('已清空所有数据')));
      }
    }
  }
}

/// 内容区：页头（图标块 + 标题 + 副标题 + 引擎状态胶囊）+ 分类内容。
class _SectionContent extends StatelessWidget {
  final _SectionMeta section;
  final bool engineNull;
  final Color accent;
  final Widget child;
  const _SectionContent({
    required this.section,
    required this.engineNull,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PageHeader(section: section, engineNull: engineNull),
                const SizedBox(height: 20),
                if (engineNull) const _EngineNullBanner(),
                child,
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 页头：强调色图标块 + SpaceGrotesk 标题 + 副标题 + 引擎状态胶囊。
class _PageHeader extends StatelessWidget {
  final _SectionMeta section;
  final bool engineNull;
  const _PageHeader({required this.section, required this.engineNull});

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Row(
      children: [
        // 图标块（强调色 24% 底 + 强调色图标）
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: accent.withAlpha(0x24),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(section.icon, size: 22, color: accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(section.title,
                  key: Key('sec_${section.key}'),
                  style: WlText.display(fontSize: 22)),
              const SizedBox(height: 3),
              Text(section.subtitle,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        _EnginePill(ready: !engineNull),
      ],
    );
  }
}

/// 引擎健康度胶囊：绿点=就绪，黄点=未加载。
class _EnginePill extends StatelessWidget {
  final bool ready;
  const _EnginePill({required this.ready});

  @override
  Widget build(BuildContext context) {
    final color = ready ? AppTheme.ok : AppTheme.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(0x14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(0x50)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(ready ? '引擎就绪' : '引擎未加载',
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 引擎未加载提示横幅。
class _EngineNullBanner extends StatelessWidget {
  const _EngineNullBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.warn.withAlpha(0x0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warn.withAlpha(0x40)),
      ),
      child: const Row(
        children: [
          Icon(LucideIcons.alertCircle, size: 16, color: AppTheme.warn),
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
  }
}

/// AutoEQ 型号 tile：选中时强调色勾选 + 文字高亮。
class _AutoEqTile extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  const _AutoEqTile({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? accent.withAlpha(0x12) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: selected
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400)),
              ),
              if (selected)
                Icon(LucideIcons.check, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置页左侧导航栏：品牌 + 分类 + 底部引擎状态。
class _SettingsRail extends StatelessWidget {
  final int activeIndex;
  final bool engineReady;
  final ValueChanged<int> onSelect;
  const _SettingsRail({
    required this.activeIndex,
    required this.engineReady,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Container(
      width: 230,
      decoration: const BoxDecoration(
        color: AppTheme.s2,
        border: Border(right: BorderSide(color: AppTheme.highlightStrong)),
      ),
      child: Column(
        children: [
          // 品牌区：返回主页按钮 + WaveLink 标识
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
            child: Row(
              children: [
                // 返回主页按钮
                Material(
                  color: AppTheme.s3,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    key: const Key('settings_back'),
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.highlightStrong),
                      ),
                      child: const Icon(LucideIcons.arrowLeft,
                          size: 18, color: AppTheme.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('WaveLink',
                        style: TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppTheme.textPrimary,
                            letterSpacing: -0.3)),
                    Text('设置 SETTINGS',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 10,
                            letterSpacing: 0.8)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppTheme.divider),
          // 分类导航
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
              itemCount: _SettingsScreenState._sections.length,
              itemBuilder: (c, i) {
                final m = _SettingsScreenState._sections[i];
                final active = i == activeIndex;
                return _RailItem(
                  key: Key('nav_${m.key}'),
                  icon: m.icon,
                  label: m.title,
                  active: active,
                  accent: accent,
                  onTap: () => onSelect(i),
                );
              },
            ),
          ),
          // 底部引擎状态
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.divider)),
            ),
            child: _EnginePill(ready: engineReady),
          ),
        ],
      ),
    );
  }
}

/// 导航单项：选中时强调色左侧条 + 图标着色 + s3 底，hover 淡白。
class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: active ? AppTheme.s3 : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border(
                left: active
                    ? BorderSide(color: accent, width: 3)
                    : const BorderSide(color: Colors.transparent, width: 3),
              ),
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 17,
                    color: active ? accent : AppTheme.textTertiary),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          color: active
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                          fontSize: 13,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400)),
                ),
                if (active)
                  Icon(LucideIcons.chevronRight,
                      size: 14, color: accent.withAlpha(0x66)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
