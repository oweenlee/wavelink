import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../data/services/log.dart';
import '../../../../data/services/smb_service.dart';
import '../../../../data/services/webdav_service.dart';
import '../../../../domain/models/song.dart';
import '../../../core/providers/repositories.dart';

/// 封面提取调度：从 LibraryNotifier 拆出的独立职责单元。
///
/// 两条提取通道：
/// - NAS 索引歌（无本地文件）：远端读头部提取（[extractNasCovers]）；
/// - 有本地文件的歌：Rust 引擎读取提取（[extractLocalCovers]）。
///
/// 提取完成通过 [onCoversUpdated] 回调通知上层刷新 UI 并持久化
/// （Song.coverUrl 为可变字段，需上层重建 state 触发监听）。
class CoverService {
  CoverService(this._ref, {this.onCoversUpdated});

  final Ref _ref;

  /// 封面就绪回调（上层刷新 UI + 持久化曲库）
  final VoidCallback? onCoversUpdated;

  /// SMB 封面提取组内并发：历史 4 曾触发 NAS 连接数限制整批超时，
  /// 但彼时每任务临时新建连接、无池约束；现 Rust 侧有 8 连接池 + 信号量，
  /// 4 并发安全。若 NAS 对并发连接敏感，调回 2。
  static const _smbCoverGroupSize = 4;

  /// NAS 远端封面/元数据批量提取（并发 2），完成后回调刷新。
  /// 失败静默：封面保持纯色占位，不影响曲库。
  /// 每批前先探活：发现死连接先重建，避免整批请求同时踩
  /// 死连接各白等超时；会话不可用则中止本轮，续跑循环稍后再提。
  /// 待提取队列（防重入 + 续跑）：多次触发（启动恢复/扫描完成）合并，
  /// 封面与元数据都已就绪的歌自动剔除。
  final List<Song> _nasQueue = [];
  bool _extractingNas = false;

  /// 单曲连续失败计数：提取 3 轮仍无封面（真无封面/格式不支持）→ 放弃
  /// 保持占位色，避免永远留在队列里被无限重试。
  final Map<String, int> _nasFailCount = {};

  /// NAS 数据源更换（切换/删除 NAS 配置）时调用：
  /// 清空待提取队列与单曲失败计数，避免旧服务器的歌被旧循环误处理、
  /// 以及失败计数按 id（不含服务器指纹）跨配置残留——新旧服务器共享
  /// 路径相同时 id 相同，残留计数会让新歌被直接放弃提取封面。
  /// 旧的提取循环下一轮会发现队列已空而自然退出，新导入的歌会在
  /// 扫描完成后重新触发提取，不会丢失。
  void resetForConfigChange() {
    _nasQueue.clear();
    _nasFailCount.clear();
  }

  /// NAS 封面提取：低优先级后台任务，播放/下载时让路但**自动续跑**
  /// （历史问题：让路 break 后整个提取永久退出，剩余封面再也不提，
  /// 表现为"封面没有全解析出来"）。
  ///
  /// 并发 2（串行太慢：数百首歌每首一次 SMB 读头+解析，单并发要几分钟；
  /// 4 并发曾触发 NAS 连接数限制导致整批超时）。播放让路 + 熔断冷却
  /// 保护仍保留，配合续跑循环在播放间隙自动补齐。
  /// 有进展时仅短暂防抖立即续跑，无进展（让路/冷却/失败）才等长间隔。
  Future<void> extractNasCovers(List<Song> songs) async {
    if (songs.isEmpty) return;
    _nasQueue.addAll(songs);
    if (_extractingNas) return; // 已有提取循环在跑，新请求已并入队列
    _extractingNas = true;
    try {
      var idleRounds = 0; // 连续无进展轮数（会话死亡/熔断冷却），超限停止避免空转
      while (true) {
        final pending = pendingNasCovers(_nasQueue);
        if (pending.isEmpty) {
          _nasQueue.clear();
          break;
        }
        final progressed = await _extractNasPass(pending);
        // 封面+元数据都已就绪的从队列剔除；连续 3 轮无进展
        //（真无封面且文件无标签）也剔除，避免无限重试
        _nasQueue.removeWhere((s) =>
            (s.coverUrl != null && !_needsMetadataFor(s)) ||
            (_nasFailCount[s.id] ?? 0) >= 3);
        // 每轮结束即刷新：已解析的封面及时上屏（历史问题：只在全部
        // 完成/放弃后刷一次，数百首歌要等几分钟 UI 才更新）
        onCoversUpdated?.call();
        if (progressed) {
          idleRounds = 0;
          // 有进展：立即续跑，不再额外等待。历史 bug：无条件等 15s，
          // 700 首歌回填要 350 轮 × 15s ≈ 90 分钟；后改为 300ms 防抖，
          // 但数百首歌每轮 8 首仍有 60+ 轮 × 300ms ≈ 20s 纯空等。
          // 每轮内本就有网络往返耗时，无需叠加防抖延迟。
        } else {
          idleRounds++;
          if (idleRounds >= 8) {
            Log.w('Cover', '封面提取连续无进展，暂停续跑（剩余 ${pendingNasCovers(_nasQueue).length}）');
            break;
          }
          // 播放让路/熔断冷却/失败后：等 15s 再续（播放间隙自动补齐）
          await Future.delayed(const Duration(seconds: 15));
        }
      }
    } finally {
      _extractingNas = false;
    }
    onCoversUpdated?.call();
  }

  /// 单轮提取：一轮 8 首、组内并发 2（NAS 连接数限制），
  /// 播放/下载活跃或会话不可用时让路返回。
  /// 返回本轮是否有进展（至少解析出一张封面/回填一组元数据）。
  Future<bool> _extractNasPass(List<Song> songs) async {
    var progressed = false;
    // 批内是否存在 SMB 歌：SMB 有连接数限制/熔断/会话探活需要让路与
    // 前置检查；WebDAV 走 reqwest 无此限制，直接提取即可。
    final hasSmb =
        songs.any((s) => s.smbPath != null && s.smbPath!.isNotEmpty);
    // 轮大小：SMB 受限 8 首/轮；纯 WebDAV 放开（并发 6）提速
    final roundSize = hasSmb ? 8 : 24;
    for (var i = 0; i < songs.length; i += roundSize) {
      // 播放/下载进行中：让路（不打断播放），由外层循环稍后继续
      if (hasSmb && SmbService.playbackActive) {
        Log.d('Cover', '播放/下载活跃，暂停封面提取（已完成 $i/${songs.length}）');
        return progressed || i > 0;
      }
      // 熔断冷却中：本轮跳过（未尝试不算失败，避免冷却轮误计单曲失败）
      if (hasSmb && SmbService.coverCooldownActive) {
        Log.d('Cover', '封面提取冷却中，本轮跳过（已完成 $i/${songs.length}）');
        return progressed || i > 0;
      }
      if (hasSmb && !await SmbService.ensureHealthy()) {
        Log.w('Cover', '会话不可用，中止本轮封面提取（已完成 $i/${songs.length}）');
        return progressed || i > 0;
      }
      final end = (i + roundSize > songs.length) ? songs.length : i + roundSize;
      final batch = songs.sublist(i, end);
      // 组内并发：SMB 用 4。历史 4 并发曾触发 NAS 连接数限制整批超时，
      // 但彼时每任务临时新建连接、无池约束；现 Rust 侧已有 8 连接池 +
      // 信号量保护（smb.rs READ_POOL_SIZE=8 / POOL_SEM_PERMITS=10），
      // 4 并发封面 + 1 播放流 ≤ 池容量。若你的 NAS 对并发连接仍敏感，
      // 调回 2 即可（见 [_smbCoverGroupSize]）。
      // 纯 WebDAV 走 reqwest 无连接数限制，放开到 6 提速。
      final groupSize = hasSmb ? _smbCoverGroupSize : 6;
      for (var j = 0; j < batch.length; j += groupSize) {
        final subEnd =
            (j + groupSize > batch.length) ? batch.length : j + groupSize;
        final sub = batch.sublist(j, subEnd);
        // 按源分流：SMB 走 SmbService（含熔断计数），WebDAV 走
        // WebdavService（Range 读头）。返回是否有进展（拿到封面或
        // 回填了元数据），只盯 coverUrl 会把"无封面但元数据已回填"
        // 的歌误判为失败。
        final results = await Future.wait(sub.map((s) {
          if (s.smbPath != null && s.smbPath!.isNotEmpty) {
            return SmbService.fetchRemoteCover(s);
          }
          if (s.davPath != null && s.davPath!.isNotEmpty) {
            return WebdavService.fetchRemoteCover(s);
          }
          // STRM 歌：按 Resolver 落地的目标走对应源提取
          return s.targetKind == 'smb'
              ? SmbService.fetchRemoteCover(s)
              : WebdavService.fetchRemoteCover(s);
        }));
        for (var k = 0; k < sub.length; k++) {
          final s = sub[k];
          if (results[k]) {
            _nasFailCount.remove(s.id);
            progressed = true;
          } else {
            final c = (_nasFailCount[s.id] ?? 0) + 1;
            _nasFailCount[s.id] = c;
            if (c >= 3) {
              Log.d(
                'Cover',
                '3 轮无进展，放弃提取: ${s.title} (${s.smbPath ?? s.davPath})',
              );
            }
          }
        }
      }
    }
    return progressed;
  }

  /// 本地文件封面批量提取（限流并发 4，避免打满 FRB 线程池），
  /// 完成后有变更才回调刷新。
  Future<void> extractLocalCovers(List<Song> songs) async {
    final engineRepo = _ref.read(audioEngineRepositoryProvider);
    if (!engineRepo.rustAvailable) return;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/.covers');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

    // 待处理的歌曲（无封面缓存、本地文件真实存在）。
    // 不依赖 hasCover 标记（_fileToSong 降级导入时未设）；
    // NAS 缓存路径的本地文件可能已被清理/未下载 → 跳过，
    // 避免 lofty 读取不存在的文件（No such file or directory）。
    final pending = <Song>[];
    for (final s in songs) {
      if (s.path == null || s.coverUrl != null) continue;
      if (!await File(s.path!).exists()) continue;
      pending.add(s);
    }
    if (pending.isEmpty) return;

    var changed = false;
    const batchSize = 4;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(
        i,
        i + batchSize > pending.length ? pending.length : i + batchSize,
      );
      await Future.wait(batch.map((song) async {
        final cacheFile = File('${cacheDir.path}/${song.path!.hashCode}.jpg');
        if (await cacheFile.exists()) {
          song.coverUrl = cacheFile.path;
          changed = true;
          return;
        }
        try {
          final bytes = await engineRepo.getCoverBytes(song.path!);
          await cacheFile.writeAsBytes(bytes);
          song.coverUrl = cacheFile.path;
          changed = true;
        } catch (e) {
          Log.e('Cover', '提取封面失败: $e');
        }
      }));
    }
    if (changed) onCoversUpdated?.call();
  }

  /// 筛选待处理的远端索引歌（无本地文件，需远端读头）：
  /// 缺封面，或元数据仍是扫描期占位值（album/artist/时长需回填）。
  /// 支持 SMB（smbPath）与 WebDAV（davPath）两个源。
  static List<Song> pendingNasCovers(List<Song> songs) => songs
      .where((s) =>
          ((s.smbPath != null && s.smbPath!.isNotEmpty) ||
              (s.davPath != null && s.davPath!.isNotEmpty) ||
              // STRM 歌：Resolver 已落地 smb/dav 目标 → 参与封面提取
              (s.isStrm &&
                  (s.targetKind == 'smb' || s.targetKind == 'dav'))) &&
          s.path == null &&
          (s.coverUrl == null || _needsMetadataFor(s)))
      .toList();

  /// 按源判断元数据是否仍为扫描期占位值（SMB/WebDAV 各自占位常量不同）。
  static bool _needsMetadataFor(Song s) {
    if (s.smbPath != null || (s.isStrm && s.targetKind == 'smb')) {
      return SmbService.needsMetadata(s);
    }
    return WebdavService.needsMetadata(s);
  }

  /// 筛选缺封面且有本地文件的歌（从文件提取）
  static List<Song> pendingLocalCovers(List<Song> songs) =>
      songs.where((s) => s.path != null && s.coverUrl == null).toList();
}
