enum LoopMode { list, single, shuffle }

enum EqPresetKind {
  flat,
  rock,
  pop,
  dance,
  classical,
  soft,
  fullBass,
  fullTreble,
  techno,
  vocals,
}

class DspSettings {
  final bool enabled;
  final bool crossfeed;
  final bool widener;
  final bool limiter;
  final EqPresetKind preset;

  const DspSettings({
    this.enabled = false,
    this.crossfeed = false,
    this.widener = false,
    this.limiter = false,
    this.preset = EqPresetKind.flat,
  });

  DspSettings copyWith({
    bool? enabled,
    bool? crossfeed,
    bool? widener,
    bool? limiter,
    EqPresetKind? preset,
  }) => DspSettings(
    enabled: enabled ?? this.enabled,
    crossfeed: crossfeed ?? this.crossfeed,
    widener: widener ?? this.widener,
    limiter: limiter ?? this.limiter,
    preset: preset ?? this.preset,
  );
}

/// 引擎实时遥测（乐器面板读数）。
///
/// 所有字段均来自引擎真实 getter（采样率/underrun/播放状态），
/// 无直接 ringbuf 占用量 API，故 Buffer 健康度由 underrun 增量推算。
class EngineTelemetry {
  /// 硬件/输出采样率（Hz），0 = 未知
  final int outputRate;

  /// 当前曲目文件采样率（Hz），0 = 未知
  final int fileRate;

  /// underrun 累计总数
  final int underrunTotal;

  /// 最近一个轮询周期的 underrun 增量
  final int underrunRecent;

  /// 实际输出共享模式：0=未知/不适用，1=Exclusive，2=Shared（Android Oboe）
  final int outputMode;

  /// 引擎是否正在播放
  final bool running;

  /// ringbuf 配置容量（ms，engine_init 固定 280）
  final int bufferMs;

  const EngineTelemetry({
    required this.outputRate,
    required this.fileRate,
    required this.underrunTotal,
    required this.underrunRecent,
    required this.running,
    required this.bufferMs,
    this.outputMode = 0,
  });

  static const idle = EngineTelemetry(
    outputRate: 0,
    fileRate: 0,
    underrunTotal: 0,
    underrunRecent: 0,
    running: false,
    bufferMs: 280,
  );

  /// bit-perfect（速率维度）：文件速率与输出速率一致（不重采样）
  bool get bitPerfect => fileRate > 0 && fileRate == outputRate;

  /// 是否 Exclusive 直通（Android 实际模式，非请求偏好）
  bool get exclusiveDirect => outputMode == 1;

  /// 是否 Shared 混音器路径（Android，请求 Exclusive 被静默降级）
  bool get sharedFallback => outputMode == 2;

  /// Buffer 是否供数不足（最近周期出现 underrun）
  bool get bufferStarving => underrunRecent > 0;
}
