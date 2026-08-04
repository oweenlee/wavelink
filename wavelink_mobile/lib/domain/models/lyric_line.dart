class LyricLine {
  final double timeMs;
  final String text;

  LyricLine(this.timeMs, this.text);

  int get totalMs => timeMs.round();
}
