class LyricLine {
  final double timeMs;
  final String text;

  const LyricLine({required this.timeMs, required this.text});

  int get totalMs => timeMs.round();
}
