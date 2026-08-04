import '../../domain/models/lyric_line.dart';

/// 解析 LRC 歌词文本为按时间升序排列的 [LyricLine] 列表。
///
/// 支持：
/// - 时间标签 `[mm:ss]`、`[mm:ss.xx]`（百分秒）、`[mm:ss.xxx]`（毫秒）
/// - 一行多个时间标签：`[00:01.00][00:05.00]同一句` → 拆成两条
/// - 元数据标签（`[ti:]`/`[ar:]`/`[al:]` 等）因不含数字时间而自动忽略
///
/// 空内容或无有效时间标签返回空列表。
List<LyricLine> parseLrc(String content) {
  final result = <LyricLine>[];
  // 时间标签：[分:秒] / [分:秒.小数]，小数可为 1~3 位
  final tagRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    final matches = tagRe.allMatches(line).toList();
    if (matches.isEmpty) continue; // 纯元数据行（[ti:] 等）跳过

    // 去掉所有时间标签后剩下的歌词文本
    final text = line.replaceAll(tagRe, '').trim();
    if (text.isEmpty) continue; // 空文本占位行跳过

    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      // 小数部分归一化到毫秒：按位数补零到 3 位
      //   "5" → "500"(500ms)  "55" → "550"(550ms)  "555" → "555"(555ms)
      final frac = m.group(3);
      final ms = frac == null
          ? 0
          : int.parse(frac.padRight(3, '0').substring(0, 3));
      final timeMs = ((min * 60 + sec) * 1000 + ms).toDouble();
      result.add(LyricLine(timeMs, text));
    }
  }

  result.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return result;
}
