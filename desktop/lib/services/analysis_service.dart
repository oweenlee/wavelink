import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../src/rust/api/analyze.dart' as frb_analyze;
import 'stable_hash.dart';
import 'webdav_service.dart';

/// 音频分析服务：BPM / 调性（Key）/ 能量，带内存 + 磁盘双层缓存。
///
/// 与 mobile `audio_engine_repository` 的分析缓存语义对齐：按需分析（播放时
/// 触发），磁盘缓存 `<文档>/.analysis_cache/<fnv1a(path)>.json` 记录音频
/// 文件 mtime，二次播放命中缓存秒出，文件内容变化则自动作废重算。
class AnalysisService {
  AnalysisService._();

  static final AnalysisService instance = AnalysisService._();

  /// 内存缓存：trackId → 分析结果（session 内共享，播放页读取同步命中）。
  final Map<String, frb_analyze.AnalyzeResult> _mem = {};

  /// 分析 [path] 并缓存；失败返回 null（不阻塞播放）。
  Future<frb_analyze.AnalyzeResult?> analyze(
      String trackId, String path) async {
    final cached = _mem[trackId];
    if (cached != null) return cached;

    // 磁盘缓存（带 mtime 校验）：二次播放秒出，不重跑全曲分析
    final disk = await _loadDisk(path);
    if (disk != null) {
      _mem[trackId] = disk;
      return disk;
    }

    try {
      final result = await frb_analyze.analyzeFile(path: path);
      _mem[trackId] = result;
      unawaited(_saveDisk(path, result));
      return result;
    } catch (_) {
      // 分析失败（文件损坏/格式不支持等）：静默，UI 不显示徽章
      return null;
    }
  }

  /// 同步读取已缓存结果（播放页 build 用；未分析完返回 null）。
  frb_analyze.AnalyzeResult? get(String trackId) => _mem[trackId];

  /// 该曲目是否有本地可分析路径：本地曲目直接文件路径；
  /// WebDAV 仅在已下载缓存时可用（流式播放中途可能还没缓存完，视为不可分析）。
  Future<String?> localPathFor(Track t) async {
    switch (t.source) {
      case TrackSource.local:
        return t.filePath;
      case TrackSource.webdav:
        if (t.remotePath == null) return null;
        return WebdavService.cachedLocalPath(t.remotePath!);
      case TrackSource.nas:
      case TrackSource.subsonic:
        return null;
    }
  }

  // ── 磁盘缓存 ──

  Future<File?> _cacheFile(String path) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, '.analysis_cache'));
      return File('${dir.path}/${fnv1a(path)}.json');
    } catch (_) {
      return null;
    }
  }

  Future<frb_analyze.AnalyzeResult?> _loadDisk(String path) async {
    try {
      final file = await _cacheFile(path);
      if (file == null || !await file.exists()) return null;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final mtimeMs = await File(path).lastModified();
      // 音频文件内容已变化（路径复用但 mtime 不同）→ 缓存作废重算
      if (data['mtimeMs'] != mtimeMs.millisecondsSinceEpoch) return null;
      return frb_analyze.AnalyzeResult(
        bpm: (data['bpm'] as num?)?.toDouble(),
        key: data['key'] as String?,
        energy: (data['energy'] as num?)?.toDouble(),
        bpmConfidence: (data['bpmConfidence'] as num?)?.toDouble(),
        keyConfidence: (data['keyConfidence'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDisk(String path, frb_analyze.AnalyzeResult result) async {
    try {
      final file = await _cacheFile(path);
      if (file == null) return;
      await file.parent.create(recursive: true);
      final mtimeMs = await File(path).lastModified();
      await file.writeAsString(jsonEncode({
        'mtimeMs': mtimeMs.millisecondsSinceEpoch,
        'bpm': result.bpm,
        'key': result.key,
        'energy': result.energy,
        'bpmConfidence': result.bpmConfidence,
        'keyConfidence': result.keyConfidence,
      }));
    } catch (_) {
      // 缓存写入失败不影响播放
    }
  }
}