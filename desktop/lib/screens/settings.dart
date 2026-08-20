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
import '../widgets/settings_controls.dart';
import '../widgets/settings_rail.dart';
import '../widgets/settings_section.dart';
import '../widgets/setting_tiles.dart';

/// 设置页（桌面端）：语言 / 数据管理 + 音频输出 / DSP / 诊断。
///
/// 布局「左侧导航 + 右侧内容」主从结构（框架组件见 `widgets/settings_rail.dart`
/// 与 `widgets/settings_section.dart`，控件基元见 `widgets/settings_controls.dart`）。
/// 视觉延续灰阶哲学，控件层使用 [SettingTile] / [SettingGroup] 统一组件保证一致性。
///
/// 音频/DSP 设置与 [PlayerController.init] 的 `_restoreAudioSettings` 同源
/// 读写 SharedPreferences（启动恢复、即时落盘，「清空所有数据」一并清除）。
class SettingsScreen extends ConsumerStatefulWidget {
  final PlayerController player;
  const SettingsScreen({super.key, required this.player});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Engine? get engine => widget.player.engine;

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

  // ── 即时落盘 ──
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
    final engineNull = engine == null;
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

  // ───────────────────────── 通用 ─────────────────────────

  Widget _buildGeneral() {
    final mode = ref.watch(localeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroup(
          icon: LucideIcons.languages,
          title: '界面语言',
          description: '选择应用界面的显示语言',
          tiles: [
            SettingTile(
              icon: LucideIcons.globe,
              title: '显示语言',
              description: '更改后立即生效',
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
                          child: Text(_localeLabels[k]!,
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
          title: '数据管理',
          description: '管理本地曲库与缓存数据',
          tiles: [
            SettingTile(
                icon: LucideIcons.trash2,
                title: '清空所有数据',
                description: '删除全部曲库、收藏与播放列表（不可恢复）',
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
                  label: const Text('清空所有数据'),
                ),
            ),
          ],
        ),
      ],
    );
  }

  // ───────────────────────── 音频输出 ─────────────────────────

  Widget _buildAudio() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingGroup(
            icon: LucideIcons.headphones,
            title: '输出设备',
            description: '选择音频输出设备与独占模式',
            tiles: [
              SettingTile(
                icon: LucideIcons.speaker,
                title: '设备',
                description: _selectedDevice ?? '系统默认输出',
                trailing: SettingDropdown<String?>(
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
              ),
              SettingTile(
                icon: LucideIcons.gauge,
                title: '当前状态',
                child: TechChips(children: [
                  TechChip(label: '模式', value: _exclusive ? '独占' : '共享'),
                  TechChip(
                      label: '采样率',
                      value: _actualSr != null ? '$_actualSr Hz' : '—'),
                ]),
              ),
              if (Platform.isWindows || Platform.isMacOS)
                SettingTile(
                  key: const Key('sw_exclusive'),
                  icon: LucideIcons.lock,
                  title: Platform.isWindows
                      ? 'WASAPI 独占模式'
                      : 'Hog Mode 独占模式',
                  description: '独占音频设备，切换将重启引擎',
                  trailing: AccentSwitch(
                    value: _exclusive,
                    onChanged: (v) async {
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
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SettingGroup(
            icon: LucideIcons.waves,
            title: '采样率',
            description: '设置输出采样率（下次播放生效）',
            tiles: [
              SettingTile(
                icon: LucideIcons.hash,
                title: '输出采样率 (Hz)',
                description: '常用值：44100（CD）、48000、96000、192000',
                child: Row(
                  children: [
                    Expanded(
                      child: SettingTextField(
                        key: const Key('sr_field'),
                        controller: _srController,
                        hint: '44100',
                      ),
                    ),
                    const SizedBox(width: 10),
                    SettingPrimaryButton(
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
              ),
            ],
          ),
          const SizedBox(height: 14),
          SettingGroup(
            icon: LucideIcons.zap,
            title: '高级',
            description: 'Bit-Perfect、自动采样率与无缝切换',
            tiles: [
              SettingTile(
                key: const Key('sw_bitperfect'),
                icon: LucideIcons.shieldCheck,
                title: 'Bit-Perfect 直通',
                description: '绕过采样率转换与 DSP，原始信号直出；切换将重启引擎',
                trailing: AccentSwitch(
                  value: _bitPerfect,
                  onChanged: (v) async {
                    setState(() {
                      _bitPerfect = v;
                      _saveBool('engine.bitPerfect', v);
                    });
                    // 立即重初始化使开关生效（此前仅落盘，用户以为生效实际没有）
                    final messenger = ScaffoldMessenger.of(context);
                    final err = await engine?.reinitialize(bitPerfect: v);
                    if (err != null && mounted) {
                      messenger.showSnackBar(
                          SnackBar(content: Text('Bit-Perfect 切换失败：$err')));
                    }
                    _refreshSr();
                  },
                ),
              ),
              SettingTile(
                key: const Key('sw_autosr'),
                icon: LucideIcons.refreshCw,
                title: '自动采样率',
                description: '按源文件采样率自动切换输出；切换将重启引擎',
                trailing: AccentSwitch(
                  value: _autoSampleRate,
                  onChanged: (v) async {
                    setState(() {
                      _autoSampleRate = v;
                      _saveBool('engine.autoSampleRate', v);
                    });
                    // 立即重初始化使开关生效（此前仅落盘，用户以为生效实际没有）
                    final messenger = ScaffoldMessenger.of(context);
                    final err = await engine?.reinitialize(autoSampleRate: v);
                    if (err != null && mounted) {
                      messenger.showSnackBar(
                          SnackBar(content: Text('自动采样率切换失败：$err')));
                    }
                    _refreshSr();
                  },
                ),
              ),
              SettingTile(
                icon: LucideIcons.shuffle,
                title: '曲间无缝 Crossfade',
                description: '下一首启动生效',
                child: SliderWithLabel(
                  value: _crossfadeMs,
                  min: 0,
                  max: 8000,
                  divisions: 32,
                  fmt: (v) =>
                      v == 0 ? '关闭' : '${v.round()} ms',
                  onChanged: (v) {
                    setState(() {
                      _crossfadeMs = v;
                      _saveInt('engine.crossfadeMs', v.round());
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      );

  // ───────────────────────── DSP 效果 ─────────────────────────

  Widget _buildDsp() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingGroup(
            icon: LucideIcons.expand,
            title: '空间效果',
            description: '立体声展宽与跨馈处理',
            tiles: [
              SettingTile(
                key: const Key('sw_立体声展宽'),
                icon: LucideIcons.moveHorizontal,
                title: '立体声展宽',
                description: '扩展立体声声场宽度',
                trailing: AccentSwitch(
                  value: _widenerOn,
                  onChanged: (v) {
                    setState(() {
                      _widenerOn = v;
                      _saveBool('dsp.widener', v);
                    });
                    engine?.setStereoWidener(v, _widenerWidth);
                  },
                ),
              ),
              if (_widenerOn)
                SettingTile(
                  icon: LucideIcons.slidersHorizontal,
                  title: '展宽宽度',
                  child: SliderWithLabel(
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
                ),
              SettingTile(
                key: const Key('sw_跨馈 (Crossfeed)'),
                icon: LucideIcons.headphones,
                title: '跨馈 (Crossfeed)',
                description: '耳机听感模拟音箱串扰，减少疲劳',
                trailing: AccentSwitch(
                  value: _crossfeed,
                  onChanged: (v) {
                    setState(() {
                      _crossfeed = v;
                      _saveBool('dsp.crossfeed', v);
                    });
                    engine?.setCrossfeed(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SettingGroup(
            icon: LucideIcons.activity,
            title: '动态处理',
            description: '限幅、抖动与噪声整形',
            tiles: [
              SettingTile(
                key: const Key('sw_真峰值限幅 (Limiter)'),
                icon: LucideIcons.shield,
                title: '真峰值限幅 (Limiter)',
                description: '防止削波失真',
                trailing: AccentSwitch(
                  value: _limiter,
                  onChanged: (v) {
                    setState(() {
                      _limiter = v;
                      _saveBool('dsp.limiter', v);
                    });
                    engine?.setLimiter(v);
                  },
                ),
              ),
              SettingTile(
                icon: LucideIcons.grid2x2,
                title: '抖动 (Dither)',
                description: '低位深输出时降低量化噪声',
                trailing: AccentSwitch(
                  value: _dither,
                  onChanged: (v) {
                    setState(() {
                      _dither = v;
                      _saveBool('dsp.dither', v);
                    });
                    engine?.setDither(v);
                  },
                ),
              ),
              SettingTile(
                icon: LucideIcons.audioWaveform,
                title: '噪声整形 (Noise Shaping)',
                description: '将量化噪声推向高频不可闻区',
                trailing: AccentSwitch(
                  value: _noiseShaping,
                  onChanged: (v) {
                    setState(() {
                      _noiseShaping = v;
                      _saveBool('dsp.noiseShaping', v);
                    });
                    engine?.setNoiseShaping(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SettingGroup(
            icon: LucideIcons.trendingUp,
            title: '增益与速度',
            description: 'ReplayGain 增益补偿与播放速度',
            tiles: [
              SettingTile(
                icon: LucideIcons.volume2,
                title: 'ReplayGain 增益',
                description: '音量标准化补偿',
                child: SliderWithLabel(
                  value: _gain,
                  min: -12,
                  max: 12,
                  fmt: (v) => '${v.toStringAsFixed(1)} dB',
                  onChanged: (v) {
                    setState(() {
                      _gain = v;
                      _saveDouble('dsp.gain', v);
                    });
                    engine?.setReplaygainGain(v);
                  },
                ),
              ),
              SettingTile(
                icon: LucideIcons.gauge,
                title: '播放速度',
                description: '变速播放（不改音高）',
                child: SliderWithLabel(
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
              ),
            ],
          ),
          const SizedBox(height: 14),
          SettingGroup(
            icon: LucideIcons.slidersVertical,
            title: '均衡器',
            description: 'EQ 预设与 AutoEQ 耳机校正',
            tiles: [
              SettingTile(
                icon: LucideIcons.listMusic,
                title: 'EQ 预设',
                description: '选择预设均衡器曲线',
                trailing: SettingDropdown<String>(
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
                                    color: AppTheme.textPrimary,
                                    fontSize: 13)),
                          ))
                      .toList(),
                ),
              ),
              SettingTile(
                icon: LucideIcons.headphones,
                title: 'AutoEQ 耳机型号',
                description: _autoEq.isEmpty ? '未启用 AutoEQ 校正' : _autoEq,
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
                        Text(
                          '选择',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12),
                        ),
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
            title: '房间校正',
            description: '载入 FIR 脉冲响应或从 REW 测量生成',
            tiles: [
              SettingTile(
                icon: LucideIcons.fileAudio,
                title: 'FIR 脉冲响应 (.wav)',
                description: _irPath.isEmpty ? '未载入' : _irPath.split('/').last,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
              ),
              SettingTile(
                icon: LucideIcons.wand2,
                title: '从 REW 生成校正 IR',
                description: '导入 REW 频响测量文本 (.txt) 自动生成',
                trailing: OutlinedButton.icon(
                  onPressed: _generateRew,
                  icon: const Icon(LucideIcons.wand2,
                      size: 15, color: AppTheme.textSecondary),
                  label: const Text('生成'),
                ),
              ),
            ],
          ),
        ],
      );

  // ───────────────────────── 诊断 ─────────────────────────

  Widget _buildDiag() {
    final engineReady = engine != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MetricCard(
              icon: LucideIcons.gauge,
              label: 'UNDERRUN',
              value: '$_underrun',
              valueColor: _underrun > 0 ? AppTheme.warn : AppTheme.ok,
            ),
            const SizedBox(width: 12),
            MetricCard(
              icon: LucideIcons.waves,
              label: '采样率',
              value: _actualSr != null ? '$_actualSr Hz' : '—',
            ),
            const SizedBox(width: 12),
            MetricCard(
              icon: engineReady
                  ? LucideIcons.circleCheck
                  : LucideIcons.circleAlert,
              label: '引擎状态',
              value: engineReady ? '就绪' : '未加载',
              valueColor: engineReady ? AppTheme.ok : AppTheme.warn,
            ),
          ],
        ),
        const SizedBox(height: 14),
        SettingGroup(
          icon: LucideIcons.terminal,
          title: '运行详情',
          description: '当前播放路径与最后错误信息',
          tiles: [
            SettingTile(
              icon: LucideIcons.music,
              title: '当前曲目',
              child: SelectableText(
                _currentPath.isEmpty ? '—' : _currentPath,
                style: WlText.mono(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
            SettingTile(
              icon: LucideIcons.alertCircle,
              title: '最后错误',
              child: SelectableText(
                _lastError.isEmpty ? '无' : _lastError,
                style: WlText.mono(
                  fontSize: 12,
                  color: _lastError.isEmpty
                      ? AppTheme.textTertiary
                      : AppTheme.warn,
                ),
              ),
            ),
            SettingTile(
              icon: LucideIcons.refreshCw,
              title: '自动刷新',
              description: '每 2 秒自动更新诊断数据',
              trailing: OutlinedButton.icon(
                onPressed: () => _refreshDiagnostic(),
                icon: const Icon(LucideIcons.rotateCw,
                    size: 15, color: AppTheme.textSecondary),
                label: const Text('立即刷新'),
              ),
            ),
          ],
        ),
      ],
    );
  }

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

  /// AutoEQ 型号选择。
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
              AutoEqTile(
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
              ...catalog.map((m) => AutoEqTile(
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

  /// 从 REW 频响测量文本生成校正 FIR。
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
