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

/// 设置页（桌面端）：语言 / 数据管理 + 音频输出 / DSP / 诊断。
///
/// 布局「左侧导航 + 右侧内容」主从结构。视觉延续灰阶哲学，控件层
/// 使用 [SettingTile] / [SettingGroup] 统一组件保证一致性。
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
              trailing: _dropdown<String>(
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
                trailing: _dropdown<String?>(
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
                child: _chips([
                  _chip('模式', _exclusive ? '独占' : '共享'),
                  _chip('采样率', _actualSr != null ? '$_actualSr Hz' : '—'),
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
                  trailing: _accentSwitch(
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
                      child: _field(
                        key: const Key('sr_field'),
                        controller: _srController,
                        hint: '44100',
                      ),
                    ),
                    const SizedBox(width: 10),
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
                trailing: _accentSwitch(_bitPerfect, (v) async {
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
                }),
              ),
              SettingTile(
                key: const Key('sw_autosr'),
                icon: LucideIcons.refreshCw,
                title: '自动采样率',
                description: '按源文件采样率自动切换输出；切换将重启引擎',
                trailing: _accentSwitch(_autoSampleRate, (v) async {
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
                }),
              ),
              SettingTile(
                icon: LucideIcons.shuffle,
                title: '曲间无缝 Crossfade',
                description: '下一首启动生效',
                child: _sliderWithLabel(
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
                trailing: _accentSwitch(_widenerOn, (v) {
                  setState(() {
                    _widenerOn = v;
                    _saveBool('dsp.widener', v);
                  });
                  engine?.setStereoWidener(v, _widenerWidth);
                }),
              ),
              if (_widenerOn)
                SettingTile(
                  icon: LucideIcons.slidersHorizontal,
                  title: '展宽宽度',
                  child: _sliderWithLabel(
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
                trailing: _accentSwitch(_crossfeed, (v) {
                  setState(() {
                    _crossfeed = v;
                    _saveBool('dsp.crossfeed', v);
                  });
                  engine?.setCrossfeed(v);
                }),
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
                trailing: _accentSwitch(_limiter, (v) {
                  setState(() {
                    _limiter = v;
                    _saveBool('dsp.limiter', v);
                  });
                  engine?.setLimiter(v);
                }),
              ),
              SettingTile(
                icon: LucideIcons.grid2x2,
                title: '抖动 (Dither)',
                description: '低位深输出时降低量化噪声',
                trailing: _accentSwitch(_dither, (v) {
                  setState(() {
                    _dither = v;
                    _saveBool('dsp.dither', v);
                  });
                  engine?.setDither(v);
                }),
              ),
              SettingTile(
                icon: LucideIcons.audioWaveform,
                title: '噪声整形 (Noise Shaping)',
                description: '将量化噪声推向高频不可闻区',
                trailing: _accentSwitch(_noiseShaping, (v) {
                  setState(() {
                    _noiseShaping = v;
                    _saveBool('dsp.noiseShaping', v);
                  });
                  engine?.setNoiseShaping(v);
                }),
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
                child: _sliderWithLabel(
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
                child: _sliderWithLabel(
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
                trailing: _dropdown<String>(
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
            _metricCard(
              icon: LucideIcons.gauge,
              label: 'UNDERRUN',
              value: '$_underrun',
              valueColor: _underrun > 0 ? AppTheme.warn : AppTheme.ok,
            ),
            const SizedBox(width: 12),
            _metricCard(
              icon: LucideIcons.waves,
              label: '采样率',
              value: _actualSr != null ? '$_actualSr Hz' : '—',
            ),
            const SizedBox(width: 12),
            _metricCard(
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

  // ───────────────────────── 控件基元 ─────────────────────────

  /// 技术读数 chip。
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
                  style: WlText.mono(color: AppTheme.textTertiary, fontSize: 10)),
              TextSpan(
                  text: value,
                  style: WlText.mono(color: AppTheme.textPrimary, fontSize: 10)),
            ],
          ),
        ),
      );

  Widget _chips(List<Widget> children) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: children,
      );

  /// 统一输入框。
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

  /// 统一下拉框。
  ///
  /// 值不在候选项时回退 null（显示 hint），避免 DropdownButton 构建期抛
  /// "exactly one item with value" 断言（设备拔出 / prefs 残留旧值等场景）。
  Widget _dropdown<T>({
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    String? hint,
    Key? key,
    double width = 200,
  }) {
    final T? safeValue = (value != null && items.any((i) => i.value == value))
        ? value
        : null;
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.s3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.highlightStrong),
        ),
        child: DropdownButton<T>(
            key: key,
            value: safeValue,
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
        ),
      );
  }

  /// 带等宽读数的滑块行（SettingTile.child 用）。
  Widget _sliderWithLabel({
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String Function(double) fmt,
    required ValueChanged<double> onChanged,
  }) =>
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
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(fmt(value),
                textAlign: TextAlign.end,
                style: WlText.mono(color: AppTheme.textSecondary, fontSize: 12)),
          ),
        ],
      );

  /// 强调色 Switch（与全局 AccentScope 协调）。
  Widget _accentSwitch(bool value, ValueChanged<bool> onChanged, {Key? key}) {
    final accent = AccentScope.of(context);
    return Switch(
      key: key,
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      activeThumbColor: accent.withAlpha(255),
      activeTrackColor: accent.withAlpha(0x30),
      inactiveThumbColor: AppTheme.textTertiary,
      inactiveTrackColor: AppTheme.s3,
    );
  }

  /// 实心主按钮。
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

  /// 诊断指标卡。
  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.s2,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.highlightStrong),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: (valueColor ?? AppTheme.textTertiary)
                          .withAlpha(0x14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon,
                        size: 16,
                        color: valueColor ?? AppTheme.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(value,
                  style: WlText.mono(
                      fontSize: 18,
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

// ═══════════════════════════ 统一设置组件 ═══════════════════════════

/// 设置分组卡片：带图标标题头 + 子项列表（自动分隔线）。
class SettingGroup extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? description;
  final List<Widget> tiles;

  const SettingGroup({
    super.key,
    this.icon,
    required this.title,
    this.description,
    required this.tiles,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.s2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.highlightStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分组头
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: AppTheme.textTertiary),
                  const SizedBox(width: 8),
                ],
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(description!,
                  style: const TextStyle(
                      color: AppTheme.textTertiary, fontSize: 12)),
            )
          else
            const SizedBox(height: 4),
          // 子项（自动分隔线）
          ..._tilesWithDividers(tiles),
        ],
      ),
    );
  }

  List<Widget> _tilesWithDividers(List<Widget> tiles) {
    final result = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      result.add(tiles[i]);
      if (i < tiles.length - 1) {
        result.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Divider(height: 1, thickness: 1, color: AppTheme.divider),
        ));
      }
    }
    result.add(const SizedBox(height: 6));
    return result;
  }
}

/// 统一设置项：图标 + 标题/描述 + 尾部控件或子内容。
///
/// [trailing] 用于开关/下拉等紧凑控件；[child] 用于滑块等需要整行的内容。
/// 两者不应同时使用。
class SettingTile extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? description;
  final Color? iconColor;
  final Widget? trailing;
  final Widget? child;
  final VoidCallback? onTap;

  const SettingTile({
    super.key,
    this.icon,
    required this.title,
    this.description,
    this.iconColor,
    this.trailing,
    this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 16, color: iconColor ?? AppTheme.textTertiary),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500)),
                    if (description != null) ...[
                      const SizedBox(height: 3),
                      Text(description!,
                          style: const TextStyle(
                              color: AppTheme.textTertiary, fontSize: 11.5)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          if (child != null) ...[
            const SizedBox(height: 10),
            child!,
          ],
        ],
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, child: content),
      );
    }
    return content;
  }
}

// ═══════════════════════════ 页面框架组件 ═══════════════════════════

/// 内容区：页头 + 分类内容。
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(section: section, engineNull: engineNull),
              const SizedBox(height: 22),
              if (engineNull) const _EngineNullBanner(),
              child,
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// 页头：强调色图标块 + 标题 + 副标题 + 引擎状态胶囊。
class _PageHeader extends StatelessWidget {
  final _SectionMeta section;
  final bool engineNull;
  const _PageHeader({required this.section, required this.engineNull});

  @override
  Widget build(BuildContext context) {
    final accent = AccentScope.of(context);
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accent.withAlpha(0x20),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(section.icon, size: 21, color: accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(section.title,
                  key: Key('sec_${section.key}'),
                  style: WlText.display(fontSize: 22)),
              const SizedBox(height: 2),
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

/// 引擎健康度胶囊。
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.warn.withAlpha(0x0D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warn.withAlpha(0x40)),
      ),
      child: const Row(
        children: [
          Icon(LucideIcons.alertCircle, size: 16, color: AppTheme.warn),
          SizedBox(width: 10),
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

/// AutoEQ 型号 tile。
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
              if (selected) Icon(LucideIcons.check, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置页左侧导航栏。
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
      width: 240,
      decoration: const BoxDecoration(
        color: AppTheme.s2,
        border: Border(right: BorderSide(color: AppTheme.highlightStrong)),
      ),
      child: Column(
        children: [
          // 品牌区
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Row(
              children: [
                Material(
                  color: AppTheme.s3,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    key: const Key('settings_back'),
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.highlightStrong),
                      ),
                      child: const Icon(LucideIcons.arrowLeft,
                          size: 18, color: AppTheme.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
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
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              itemCount: _SettingsScreenState._sections.length,
              itemBuilder: (c, i) {
                final m = _SettingsScreenState._sections[i];
                final active = i == activeIndex;
                return _RailItem(
                  key: Key('nav_${m.key}'),
                  icon: m.icon,
                  label: m.title,
                  subtitle: m.subtitle,
                  active: active,
                  accent: accent,
                  onTap: () => onSelect(i),
                );
              },
            ),
          ),
          // 底部引擎状态
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
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

/// 导航单项：选中时强调色左侧条 + 图标着色 + s3 底。
class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                              color: active
                                  ? AppTheme.textPrimary
                                  : AppTheme.textSecondary,
                              fontSize: 13,
                              fontWeight:
                                  active ? FontWeight.w600 : FontWeight.w400)),
                      if (subtitle != null && !active)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(subtitle!,
                              style: const TextStyle(
                                  color: AppTheme.textTertiary, fontSize: 10.5)),
                        ),
                    ],
                  ),
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
