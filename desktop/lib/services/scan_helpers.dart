/// 网络音源扫描共用工具：音频扩展名集合、文件名解析、时长估算。
/// 与 mobile `ImportService` 的同名逻辑保持一致，便于双端扫描结果对齐。
library;

/// 支持的音频扩展名（含 hi-res：DSF/DFF/APE/WV/ALAC，呼应 wavelink 的
/// 无损/高解析定位）。
const List<String> audioExtensions = [
  '.mp3',
  '.flac',
  '.wav',
  '.m4a',
  '.aac',
  '.ogg',
  '.opus',
  '.alac',
  '.ape',
  '.dsf',
  '.dff',
  '.wv',
  '.aiff',
  '.aif',
];

/// 未知艺人的统一占位符（本地/网络扫描共用，避免不同来源显示不一致）。
const String unknownArtist = '未知艺人';

/// 从文件名解析 艺人 / 标题。
/// 规则：含 " - " 按 "艺人 - 标题"；含全角括号 "（艺人）" 视为艺人在前；
/// 否则整名作标题，艺人回退 [unknownArtist]。
/// 入参可带扩展名（内部会剥掉最后一个 `.xxx` 后缀）。
(String artist, String title) parseArtistTitle(String name) {
  final base = name.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
  if (base.contains(' - ')) {
    final parts = base.split(' - ');
    final artist = parts.first.trim();
    final title = parts.sublist(1).join(' - ').trim();
    return (
      artist.isEmpty ? unknownArtist : artist,
      title.isEmpty ? base : title,
    );
  }
  if (base.contains('（') && base.contains('）')) {
    final start = base.indexOf('（');
    final end = base.lastIndexOf('）');
    final artist = base.substring(start + 1, end).trim();
    final title = (base.substring(0, start) + base.substring(end + 1)).trim();
    return (
      artist.isEmpty ? unknownArtist : artist,
      title.isEmpty ? base : title,
    );
  }
  return (unknownArtist, base.isEmpty ? name : base);
}

/// 按文件大小粗略估算时长（假设平均 1000 kbps）。
/// 仅用于对无法读取标签的网络音频占位，真实时长由扫描期参数回填。
Duration estimateDuration(int sizeBytes) {
  if (sizeBytes <= 0) return Duration.zero;
  final bits = sizeBytes * 8;
  final secs = (bits / 1000 / 1000).round(); // 1000 kbps
  return Duration(seconds: secs);
}
