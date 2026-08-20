import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/track.dart';
import '../src/rust/api/cue.dart' as frb_cue;
import '../src/rust/api/metadata.dart' as frb_metadata;
import 'cover_cache.dart';
import 'scan_helpers.dart';

// 与网络音源共用同一扩展名白名单（scan_helpers.audioExtensions），
// 保证本地与 NAS/WebDAV 扫到的曲目集合一致（含 hi-res：APE/WV/DSF/DFF/ALAC）。
List<String> get _audioExtensions => audioExtensions;

/// 元数据读取并发度。symphonia/lofty 读头很快（每首毫秒级），
/// 8 路并发足以让数千曲库在数秒内完成，且不压垮磁盘 I/O。
const int _metadataConcurrency = 8;

/// 递归扫描目录，返回按 艺人→专辑→音轨号→标题 排序的曲目列表。
///
/// 两阶段扫描：
/// 1. **CUE 展开**：解析 `.cue` 分轨表（UTF-8/GBK），整轨镜像拆成逐首
///    虚拟曲目；被 cue 引用的镜像音频文件不再作为整轨重复入库。
/// 2. **标签增强**：对每首音频经 Rust 读真实标签（标题/艺人/专辑/音轨号/
///    时长/内嵌歌词/封面），失败降级为文件名「艺人 - 标题」约定解析
///    （引擎未加载/测试环境亦同，保证扫描永远可用）。
///
/// 目录不存在 / 不可读 / 为空时返回空列表，由 UI 展示空库提示并引导用户
/// 「添加音乐文件夹」（用户添加的文件夹由 PlayerController 持久化）。
Future<List<Track>> scanFolder(String folderPath) async {
  final dir = Directory(folderPath);
  if (!await dir.exists()) return const [];

  final exts = _audioExtensions.toSet();
  final audioFiles = <File>[];
  final cueFiles = <File>[];

  try {
    await for (final entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (ext == '.cue') {
        cueFiles.add(entity);
      } else if (exts.contains(ext)) {
        audioFiles.add(entity);
      }
    }
  } catch (_) {
    // 权限拒绝（macOS 沙箱）或中途 I/O 失败：返回已扫到的部分，不崩 UI。
  }

  // 阶段 1：CUE 展开（虚拟曲目 + 镜像文件排除集）
  final cueResult = await _expandCueSheets(cueFiles);

  // 阶段 2：音频文件标签增强（排除已被 cue 拆轨的镜像文件）
  final files = audioFiles
      .where((f) => !cueResult.imagePaths.contains(_normKey(f.path)))
      .toList();
  final tracks = await _parseTracksConcurrent(files);

  tracks.addAll(cueResult.tracks);
  tracks.sort(_libraryOrder);
  return tracks;
}

/// 曲库排序：艺人 → 专辑 → 音轨号 → 标题。
/// 真实标签入库后按专辑聚拢、碟内按音轨号排列；无专辑/音轨号时退化为
/// 原有的 艺人→标题 顺序（空字符串/0 参与比较，行为兼容）。
int _libraryOrder(Track a, Track b) {
  var c = a.artist.compareTo(b.artist);
  if (c != 0) return c;
  c = (a.album ?? '').compareTo(b.album ?? '');
  if (c != 0) return c;
  c = (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
  if (c != 0) return c;
  return a.title.compareTo(b.title);
}

/// 路径归一化键（cue 镜像排除集用）：normalize + 小写，
/// 容忍 macOS 大小写不敏感文件系统的引用差异。
String _normKey(String path) => p.normalize(path).toLowerCase();

// ── CUE 展开 ──

class _CueExpansion {
  _CueExpansion(this.tracks, this.imagePaths);
  final List<Track> tracks;

  /// 被 cue 引用的镜像音频文件路径键集合（扫描时排除，避免整轨重复入库）。
  final Set<String> imagePaths;
}

/// 解析全部 cue 文件：成功则展开为虚拟曲目；单个 cue 解析失败（编码/
/// 格式/引擎未加载）静默跳过，不影响其余扫描。
Future<_CueExpansion> _expandCueSheets(List<File> cueFiles) async {
  final tracks = <Track>[];
  final imageKeys = <String>{};
  for (final cue in cueFiles) {
    try {
      final data = await cue.readAsBytes();
      final sheet = await frb_cue.parseCueBytes(
        data: data,
        baseDir: cue.parent.path,
      );
      // 展平所有 FILE 段（与 core resolve_entries 的遍历顺序一致，
      // 保证 cueTrackIndex 与引擎 play_queue_at 的下标对齐）。
      final flat = <(String, frb_cue.CueTrackResult)>[];
      for (final file in sheet.files) {
        for (final t in file.tracks) {
          flat.add((file.path, t));
        }
      }
      final total = flat.length;
      if (total == 0) continue;
      var anyPlayable = false;
      for (var i = 0; i < total; i++) {
        final (audioPath, t) = flat[i];
        if (!File(audioPath).existsSync()) continue; // 镜像缺失 → 跳过该轨
        anyPlayable = true;
        imageKeys.add(_normKey(audioPath));
        final next = i + 1 < total ? flat[i + 1].$2.startSecs : null;
        // 同名镜像下一轨起点即本轨终点；跨 FILE 段时下一轨属另一文件，
        // 终点置 null（引擎按「播到文件尾」处理，时长事件回填真实值）。
        final sameFile =
            i + 1 < total && flat[i + 1].$1 == audioPath;
        final duration = (next != null && sameFile && next > t.startSecs)
            ? Duration(milliseconds: ((next - t.startSecs) * 1000).round())
            : null;
        tracks.add(Track(
          id: '${cue.path}#${i.toString().padLeft(2, '0')}',
          title: (t.title?.isNotEmpty ?? false) ? t.title! : 'Track ${t.num}',
          artist: (t.performer?.isNotEmpty ?? false)
              ? t.performer!
              : ((sheet.performer?.isNotEmpty ?? false)
                  ? sheet.performer!
                  : unknownArtist),
          album: (sheet.title?.isNotEmpty ?? false) ? sheet.title : null,
          filePath: audioPath,
          durationHint: duration,
          trackNumber: int.tryParse(t.num),
          cuePath: cue.path,
          cueTrackIndex: i,
          cueTrackCount: total,
        ));
      }
      // 镜像文件全部缺失：cue 不可播，保留镜像整轨入库（不加排除集即可）。
      if (!anyPlayable) continue;
    } catch (e) {
      debugPrint('[scan] CUE 解析失败 ${cue.path}: $e');
    }
  }
  return _CueExpansion(tracks, imageKeys);
}

// ── 标签增强 ──

/// 并发池解析音频文件（顺序与入参一致）。
Future<List<Track>> _parseTracksConcurrent(List<File> files) async {
  // 空列表（空目录 / 全为 cue 镜像被排除）直接返回，避免
  // _metadataConcurrency.clamp(1, 0) 因 lower>upper 抛 ArgumentError，
  // 与 scanFolder「为空返回空列表」约定一致（见 L29-30）。
  if (files.isEmpty) return <Track>[];

  final results = List<Track?>.filled(files.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= files.length) return;
      results[i] = await _parseTrack(files[i]);
    }
  }

  final pool = _metadataConcurrency.clamp(1, files.length);
  await Future.wait(List.generate(pool, (_) => worker()));
  return results.whereType<Track>().toList();
}

Future<Track?> _parseTrack(File file) async {
  final name = p.basename(file.path);
  if (name.isEmpty) return null;

  // 文件名解析作兜底（标签缺失/引擎未加载时的保底，规则与网络音源共用）。
  final (fbArtist, fbTitle) = parseArtistTitle(name);

  // 查找同名 .lrc 歌词文件（同级目录，兼容大小写；都存在时优先小写）。
  String? lyricsPath;
  for (final ext in const ['.lrc', '.LRC']) {
    final candidate = '${p.withoutExtension(file.path)}$ext';
    if (File(candidate).existsSync()) {
      lyricsPath = candidate;
      break;
    }
  }

  String artist = fbArtist;
  String title = fbTitle;
  String? album;
  int? trackNumber;
  Duration? durationHint;
  String? lyricsText;

  try {
    final meta = await frb_metadata.readMetadata(path: file.path);
    if (meta.title != null && meta.title!.trim().isNotEmpty) {
      title = meta.title!.trim();
    }
    if (meta.artist != null && meta.artist!.trim().isNotEmpty) {
      artist = meta.artist!.trim();
    }
    if (meta.album != null && meta.album!.trim().isNotEmpty) {
      album = meta.album!.trim();
    }
    trackNumber = meta.trackNumber;
    if (meta.durationSecs > 0) {
      durationHint =
          Duration(milliseconds: (meta.durationSecs * 1000).round());
    }
    if (meta.lyrics != null && meta.lyrics!.trim().isNotEmpty) {
      lyricsText = meta.lyrics;
    }
    // 顺手落盘封面字节：readMetadata 已返回封面，省掉后台提取二次解析。
    // 失败不影响扫描（后台 extractCoversFor 会兜底再提一次）。
    if (meta.hasCover && meta.coverBytes.isNotEmpty) {
      await _seedCover(file.path, meta.coverBytes);
    }
  } catch (e) {
    // 引擎未加载（测试/缺 dylib）或文件解析失败：降级文件名规则。
    debugPrint('[scan] 标签读取失败，降级文件名解析 ${file.path}: $e');
  }

  return Track(
    id: file.path,
    title: title,
    artist: artist,
    album: album,
    filePath: file.path,
    lyricsPath: lyricsPath,
    lyricsText: lyricsText,
    durationHint: durationHint,
    trackNumber: trackNumber,
  );
}

/// 将扫描期已读到的封面字节直接写入封面缓存（键与 CoverCache 一致：
/// fnv1a(filePath)）。path_provider 在测试环境不可用 → 静默跳过。
Future<void> _seedCover(String filePath, List<int> bytes) async {
  try {
    final probe = Track(id: filePath, title: '', artist: '', filePath: filePath);
    final out = File(await CoverCache.instance.cacheFilePathFor(probe));
    if (!await out.exists()) {
      await out.writeAsBytes(bytes);
    }
  } catch (_) {
    // 缓存落盘失败不影响扫描结果
  }
}
