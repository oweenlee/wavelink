import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../core/providers/repositories.dart';
import '../../../../data/services/log.dart';
import '../../../../data/services/rust_service.dart' as rs;

class DspState {
  final DspSettings dspSettings;
  final List<double> eqValues;
  final String eqPreset;

  /// AutoEQ 耳机校正型号（null = 关闭）
  final String? autoEqModel;

  /// 房间校正 IR 沙盒路径（null = 未启用）
  final String? roomIrPath;

  DspState({
    DspSettings? dspSettings,
    List<double>? eqValues,
    this.eqPreset = 'Flat',
    this.autoEqModel,
    this.roomIrPath,
  }) : dspSettings = dspSettings ?? DspSettings(),
       eqValues = eqValues ?? List.filled(10, 0.0);

  DspState copyWith({
    DspSettings? dspSettings,
    List<double>? eqValues,
    String? eqPreset,
    Object? autoEqModel = _sentinel,
    Object? roomIrPath = _sentinel,
  }) {
    return DspState(
      dspSettings: dspSettings ?? this.dspSettings,
      eqValues: eqValues ?? this.eqValues,
      eqPreset: eqPreset ?? this.eqPreset,
      autoEqModel: identical(autoEqModel, _sentinel)
          ? this.autoEqModel
          : autoEqModel as String?,
      roomIrPath: identical(roomIrPath, _sentinel)
          ? this.roomIrPath
          : roomIrPath as String?,
    );
  }

  static const Object _sentinel = Object();
}

class DspNotifier extends Notifier<DspState> {
  @override
  DspState build() => DspState();

  bool get dspAvailable => true;

  Future<List<double>> getSpectrum() =>
      ref.read(audioEngineRepositoryProvider).getSpectrum();

  Future<int> getUnderrunCount() =>
      ref.read(audioEngineRepositoryProvider).getUnderrunCount();

  void toggleDspEnabled() {
    final s = state.dspSettings.copyWith(enabled: !state.dspSettings.enabled);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspEnabled(s.enabled);
    applyDsp();
  }

  void toggleCrossfeed() {
    final s = state.dspSettings.copyWith(
      crossfeed: !state.dspSettings.crossfeed,
    );
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspCrossfeed(s.crossfeed);
    applyDsp();
  }

  void toggleWidener() {
    final s = state.dspSettings.copyWith(widener: !state.dspSettings.widener);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspWidener(s.widener);
    applyDsp();
  }

  void toggleLimiter() {
    final s = state.dspSettings.copyWith(limiter: !state.dspSettings.limiter);
    state = state.copyWith(dspSettings: s);
    ref.read(preferencesRepositoryProvider).setDspLimiter(s.limiter);
    applyDsp();
  }

  // TPDF 抖动/噪声整形不在移动端暴露：双端输出均为 F32（iOS source node /
  // Android Oboe F32 流），无整数截断环节，抖动无量化可去相关。引擎默认
  // 已关闭 dither；这里仍显式下发关闭以兼容旧引擎/防止未来默认变更。

  // ── AutoEQ 耳机校正 ──

  /// 档案目录（型号名列表，设置页选择用）
  Future<List<String>> getAutoEqCatalog() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return const [];
    try {
      return await engineRepo.autoEqCatalog();
    } catch (e) {
      Log.e('AutoEQ', '获取目录失败: $e');
      return const [];
    }
  }

  /// 应用/清除耳机校正档案（null = 关闭）：持久化 + 下发引擎。
  /// 与手动 EQ 互斥：应用档案时引擎整组替换 PEQ；关闭档案时恢复已持久化
  /// 的手动 EQ 曲线（全零时为 no-op）。
  void setAutoEq(String? model) {
    state = state.copyWith(autoEqModel: model);
    ref.read(preferencesRepositoryProvider).setAutoEqModel(model);
    applyDsp();
    if (model == null) applyEqToEngine();
  }

  /// 手动 EQ 操作（拖滑块/应用预设）前调用：档案生效则先清除——互斥，
  /// 最近操作赢。await 引擎命令保证「档案清除恢复平坦」先于手动频段
  /// 写入生效（命令通道按序执行）。
  Future<void> _clearAutoEqIfActive() async {
    if (state.autoEqModel == null) return;
    state = state.copyWith(autoEqModel: null);
    ref.read(preferencesRepositoryProvider).setAutoEqModel(null);
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    await engineRepo.setAutoEq(null);
  }

  // ── 房间校正（REW 测量曲线 → 校正 FIR）──

  /// 生成 IR 的目标采样率：引擎默认输出采样率。
  /// 卷积器加载时若与管线采样率不一致会自动离线重采样，故固定 44100
  /// 生成是安全的（重采样保幅，校正频点位置漂移 < 1.5dB，见 core 测试）。
  static const int _roomIrSampleRate = 44100;

  /// REW 沙盒 IR 文件名（存 Documents 目录，复用现有沙盒约定）
  static const String _roomIrFileName = 'room_correction_ir.wav';

  /// 解析 REW 频响导出文本（导入后校验/预览用），失败抛错带原因。
  Future<List<rs.FreqPoint>> parseRewText(String text) async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return const [];
    return engineRepo.parseRewText(text);
  }

  /// Rust 侧默认校正配置（页面初始化用）
  Future<rs.CorrectionConfig> defaultCorrectionConfig() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    return engineRepo.defaultCorrectionConfig();
  }

  /// 生成房间校正并应用到引擎：
  /// REW 文本 → 校正 FIR（rust）→ 存沙盒 WAV → 加载到 DSP 卷积级 →
  /// 持久化路径（重启后由 applyDsp 恢复）。返回结果供 UI 展示报告。
  Future<rs.RoomCorrectionResult> generateAndApplyRoomCorrection({
    required String rewTxt,
    required rs.CorrectionConfig config,
  }) async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    final result = await engineRepo.generateRoomCorrection(
      rewTxt: rewTxt,
      config: config,
      sampleRate: _roomIrSampleRate,
    );
    final dir = await getApplicationDocumentsDirectory();
    final irPath = '${dir.path}/$_roomIrFileName';
    await engineRepo.saveRoomIrWav(result.ir, result.sampleRate, irPath);
    await engineRepo.loadRoomIr(irPath);
    state = state.copyWith(roomIrPath: irPath);
    await ref.read(preferencesRepositoryProvider).setRoomIrPath(irPath);
    return result;
  }

  /// 清除房间校正：引擎卷积级恢复直通，删除沙盒 WAV，清除持久化。
  Future<void> clearRoomCorrection() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (engineRepo.rustAvailable) {
      await engineRepo.clearRoomIr();
    }
    final path = state.roomIrPath;
    state = state.copyWith(roomIrPath: null);
    await ref.read(preferencesRepositoryProvider).setRoomIrPath(null);
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      } catch (e) {
        Log.e('RoomCorrection', '删除 IR 文件失败: $e');
      }
    }
  }

  /// 把当前 DSP 设置同步到引擎。
  /// enabled 为总开关：关闭时全部子开关置 false，打开时恢复各子开关状态。
  /// AutoEQ 独立于总开关（耳机校正不属于“音效渲染”范畴）。
  Future<void> applyDsp() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final dsp = state.dspSettings;
    final on = dsp.enabled;
    // async gap 后 provider 可能已 disposed，先取快照避免访问 ref/state
    final autoEq = state.autoEqModel;
    final roomIr = state.roomIrPath;
    try {
      await engineRepo.setCrossfeed(on && dsp.crossfeed);
      await engineRepo.setStereoWidener(on && dsp.widener, 0.5);
      await engineRepo.setLimiter(on && dsp.limiter);
      // 抖动/噪声整形在移动端恒关（F32 输出无整数截断，见上方注释）；
      // 显式关闭以兼容旧引擎/防止默认变更
      await engineRepo.setDither(false);
      await engineRepo.setNoiseShaping(false);
      await engineRepo.setAutoEq(autoEq);
      // 房间校正独立于总开关（与 AutoEQ 同属"校正"而非"音效渲染"）。
      // 单独 try：IR 文件被外部删除（清缓存/重装）时加载失败，
      // 不能吞进主 catch 让路径残留——每次启动反复尝试失败；
      // 应清理 state 与偏好，避免脏路径。
      if (roomIr != null) {
        try {
          await engineRepo.loadRoomIr(roomIr);
        } catch (e) {
          Log.w('DSP', '房间校正 IR 加载失败，已清理路径 ($e)');
          state = state.copyWith(roomIrPath: null);
          await ref.read(preferencesRepositoryProvider).setRoomIrPath(null);
        }
      }
    } catch (e) {
      Log.e('DSP', '应用设置失败: $e');
    }
  }

  void loadDspPrefs() {
    final prefs = ref.read(preferencesRepositoryProvider);
    final eqGains = prefs.eqGains;
    final eqPreset = prefs.eqPreset;
    // 从未保存过 EQ（无预设且无手动曲线）：保持默认 Flat 高亮
    final hasSavedEq =
        eqPreset.isNotEmpty ||
        (eqGains.length == 10 && eqGains.any((g) => g != 0.0));
    state = state.copyWith(
      dspSettings: DspSettings(
        enabled: prefs.dspEnabled,
        crossfeed: prefs.dspCrossfeed,
        widener: prefs.dspWidener,
        limiter: prefs.dspLimiter,
      ),
      autoEqModel: prefs.autoEqModel,
      roomIrPath: prefs.roomIrPath,
      eqPreset: hasSavedEq ? eqPreset : null,
      eqValues: hasSavedEq && eqGains.length == 10 ? eqGains : null,
    );
  }

  /// 把持久化的 EQ 曲线下发到引擎（启动时引擎初始化完成后调用；
  /// 预设走 applyPreset 保证与 audio-core 单一事实来源一致，
  /// 手动曲线逐频段下发）。
  Future<void> applyEqToEngine() async {
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    // async gap 后 provider 可能已 disposed，先取快照避免访问 ref/state
    final preset = state.eqPreset;
    final gains = state.eqValues;
    try {
      final rustName = _rustPresetNames[preset];
      if (rustName != null) {
        await engineRepo.applyPreset(rustName);
        return;
      }
      // 非预设（手动曲线或从未保存）：全零时无需下发
      if (gains.every((g) => g == 0.0)) return;
      for (var i = 0; i < gains.length && i < eqFrequencies.length; i++) {
        await engineRepo.setPeqBand(i, eqFrequencies[i], gains[i], eqDefaultQ);
      }
    } catch (e) {
      Log.e('EQ', '启动恢复 EQ 失败: $e');
    }
  }

  // ── 10 段参量 EQ ──

  /// EQ 频段中心频率（Hz），与 audio-core `preset_bands` 一致。
  static const List<double> eqFrequencies = [
    31,
    62,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];

  /// EQ 默认 Q 值（与 audio-core 一致）。
  static const double eqDefaultQ = 1.41;

  /// 预设增益表（dB）——与 audio-core `dsp::preset_bands` 逐值对齐，
  /// 引擎是单一事实来源：UI 显示的曲线即听到的曲线。
  static const Map<String, List<double>> eqPresets = {
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Rock': [-1.2, -1.2, -2.4, -6.5, -7.4, -5.8, -2.6, -0.7, 0.0, 0.0],
    'Pop': [-5.0, -5.0, -2.4, -1.4, -1.2, -2.2, -4.8, -5.3, -5.3, -5.0],
    'Dance': [-0.5, -0.5, -1.4, -3.4, -4.3, -4.3, -6.7, -7.2, -7.2, -4.3],
    'Classical': [-4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -4.1, -7.2, -7.2, -8.2],
    'Soft': [-2.4, -2.4, -3.6, -4.8, -5.3, -4.8, -2.6, -1.0, -0.5, 0.5],
    'Full Bass': [-0.5, -0.5, -0.5, -0.5, -1.9, -3.6, -6.0, -7.7, -8.4, -8.6],
    'Full Treble': [-8.2, -8.2, -8.2, -8.2, -6.0, -3.1, 0.0, 1.9, 1.9, 2.4],
    'Techno': [-1.2, -1.2, -1.9, -4.1, -6.5, -6.2, -4.1, -1.2, -0.5, -0.7],
    'Vocals': [-3.0, -3.0, -2.0, -0.5, 1.0, 2.5, 3.0, 1.5, 0.0, 0.0],
  };

  /// UI 预设名 → Rust 预设名（engine_apply_preset 接受的键）。
  static const Map<String, String> _rustPresetNames = {
    'Flat': 'flat',
    'Rock': 'rock',
    'Pop': 'pop',
    'Dance': 'dance',
    'Classical': 'classical',
    'Soft': 'soft',
    'Full Bass': 'full_bass',
    'Full Treble': 'full_treble',
    'Techno': 'techno',
    'Vocals': 'vocals',
  };

  /// 应用 EQ 预设：更新本地曲线、持久化并下发引擎。
  Future<void> applyEqPreset(String name) async {
    final gains = eqPresets[name];
    if (gains == null) return;
    await _clearAutoEqIfActive();
    state = state.copyWith(eqPreset: name, eqValues: List.from(gains));
    ref
        .read(preferencesRepositoryProvider)
        .setEqState(preset: name, gains: gains);
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    try {
      await engineRepo.applyPreset(
        _rustPresetNames[name] ?? name.toLowerCase(),
      );
    } catch (e) {
      Log.e('EQ', 'applyPreset 失败: $e');
    }
  }

  /// 手动调整单个频段增益：更新本地曲线、持久化并下发引擎，取消预设高亮。
  Future<void> setEqBand(int index, double gainDb) async {
    if (index < 0 || index >= state.eqValues.length) return;
    await _clearAutoEqIfActive();
    final values = List<double>.from(state.eqValues);
    values[index] = gainDb;
    // 手动调整后不再是纯预设（eqPreset 置空）
    state = state.copyWith(eqValues: values, eqPreset: '');
    ref
        .read(preferencesRepositoryProvider)
        .setEqState(preset: '', gains: values);
    final engineRepo = ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    try {
      await engineRepo.setPeqBand(
        index,
        eqFrequencies[index],
        gainDb,
        eqDefaultQ,
      );
    } catch (e) {
      Log.e('EQ', 'setPeqBand 失败: $e');
    }
  }
}

final dspProvider = NotifierProvider<DspNotifier, DspState>(DspNotifier.new);
