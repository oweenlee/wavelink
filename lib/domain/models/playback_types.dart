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
  final bool dither;
  final EqPresetKind preset;

  const DspSettings({
    this.enabled = false,
    this.crossfeed = false,
    this.widener = false,
    this.limiter = false,
    this.dither = false,
    this.preset = EqPresetKind.flat,
  });

  DspSettings copyWith({
    bool? enabled,
    bool? crossfeed,
    bool? widener,
    bool? limiter,
    bool? dither,
    EqPresetKind? preset,
  }) => DspSettings(
    enabled: enabled ?? this.enabled,
    crossfeed: crossfeed ?? this.crossfeed,
    widener: widener ?? this.widener,
    limiter: limiter ?? this.limiter,
    dither: dither ?? this.dither,
    preset: preset ?? this.preset,
  );
}
