import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../domain/models/song.dart';
import 'log.dart';

/// 曲库列表的持久化层：SQLite 单表（Documents/library.db）
///
/// 为什么从整表 JSON 迁移过来：JSON 直接写最终文件，写入中途进程被杀会截断，
/// 下次启动读到损坏文件 → 曲库静默清空。SQLite 的事务把「写入一半」变成
/// 原子操作（要么整批生效、要么回滚），彻底消除该风险；同时自带串行化
/// 写入，不再有 fire-and-forget 竞态。
///
/// 设计要点：
/// - 以 [Song.id] 为主键，saveSongs 全量替换（与旧 JSON 语义一致）。
/// - 全部写操作包在单事务内，崩溃不半成品。
/// - 沙盒内路径（path/coverUrl/lyricsPath）以相对 Documents 的形式存储：
///   iOS 重装/更新后数据容器目录会变（绝对路径全部失效），相对路径免疫。
///   沙盒外路径（系统媒体库等）原样存绝对路径。
/// - 首次打开数据库时自动迁移旧版 .library_cache.json（导入后删除），
///   老用户升级不丢曲库。
class LibraryCacheService {
  LibraryCacheService._();

  /// 数据库 schema 版本。**改表结构时必须 +1**，并在 [_onUpgrade] 里补
  /// 对应迁移语句（onCreate 建的是最新结构，老库走 onUpgrade 逐级升级）。
  static const int dbVersion = 1;

  static Database? _db;
  static bool _initDone = false;

  /// 待落盘的最新快照（覆盖式合并：连续 saveSongs 只保留最后一份）
  static List<Song>? _pending;
  static Future<void> _flushFuture = Future.value();
  static bool _flushing = false;

  /// 测试用：实际落盘次数（验证写合并生效）
  @visibleForTesting
  static int persistCount = 0;

  /// 初始化数据库后端。移动端走原生通道（iOS/Android 插件）；
  /// 桌面/测试宿主（macOS 跑 flutter test）启用 FFI。
  /// 幂等，可重复调用。
  static Future<void> init() async {
    if (_initDone) return;
    if (!kIsWeb && !(Platform.isAndroid || Platform.isIOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _initDone = true;
  }

  static Future<Database> get _database async {
    if (_db != null) return _db!;
    await init();
    final dir = await getApplicationDocumentsDirectory();
    await dir.create(recursive: true);
    _db = await openDatabase(
      '${dir.path}/library.db',
      version: dbVersion,
      onUpgrade: _onUpgrade,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE songs (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            duration_ms INTEGER NOT NULL,
            color INTEGER NOT NULL,
            has_lyrics INTEGER NOT NULL DEFAULT 0,
            bpm INTEGER,
            key TEXT,
            cover_url TEXT,
            path TEXT,
            stream_url TEXT,
            smb_path TEXT,
            dav_path TEXT,
            strm_path TEXT,
            strm_from_webdav INTEGER NOT NULL DEFAULT 0,
            target_uri TEXT,
            target_kind TEXT,
            lyrics_path TEXT,
            has_cover INTEGER NOT NULL DEFAULT 0,
            duration_estimated INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    // 首次打开：若存在旧 JSON 缓存且库内无数据，迁移后删除。
    await _migrateFromJsonIfNeeded(dir.path);
    return _db!;
  }

  /// 逐级迁移：switch 不 break，保证跨多版本的老库依次应用每一步迁移。
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // 示例（未来 v2 加列时）：
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE songs ADD COLUMN genre TEXT');
    // }
  }

  /// 保存曲库（全量替换）。写操作覆盖式合并 + 串行落盘：
  /// 扫描过程中 onBatch 每 20 首触发一次 saveSongs，N 次调用最终
  /// 只真正写盘 1~2 次，避免 O(N²/20) 的无谓 IO。失败静默记录。
  static Future<void> saveSongs(List<Song> songs) {
    _pending = List.from(songs);
    _kickFlush();
    return _flushFuture;
  }

  static void _kickFlush() {
    if (_flushing) return;
    _flushing = true;
    _flushFuture = _drain().whenComplete(() => _flushing = false);
  }

  static Future<void> _drain() async {
    while (_pending != null) {
      final snapshot = _pending!;
      _pending = null;
      await _persist(snapshot);
    }
  }

  static Future<void> _persist(List<Song> songs) async {
    persistCount++;
    try {
      final db = await _database;
      final dir = await getApplicationDocumentsDirectory();
      await db.transaction((txn) async {
        await txn.delete('songs');
        final batch = txn.batch();
        for (final s in songs) {
          batch.insert(
            'songs',
            _toRow(s, dir.path),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      Log.e('LibraryCache', '保存失败: $e');
    }
  }

  /// 读回曲库；数据库损坏/异常返回空列表（不抛给调用方）。
  static Future<List<Song>> loadSongs() async {
    try {
      // 先等未落盘的数据写完，避免读到旧快照
      await _flushFuture;
      final db = await _database;
      final dir = await getApplicationDocumentsDirectory();
      final rows = await db.query('songs');
      return rows.map((r) => _fromRow(r, dir.path)).toList();
    } catch (e) {
      Log.e('LibraryCache', '读取失败: $e');
      return [];
    }
  }

  /// 释放数据库连接（测试用）。
  @visibleForTesting
  static Future<void> close() async {
    await _flushFuture;
    await _db?.close();
    _db = null;
    _initDone = false;
    _flushing = false;
    _pending = null;
    _flushFuture = Future.value();
  }

  // ── 旧版 JSON 迁移 ──

  static Future<void> _migrateFromJsonIfNeeded(String docs) async {
    try {
      final file = File('$docs/.library_cache.json');
      if (!await file.exists()) return;
      final count = Sqflite.firstIntValue(
        await _db!.rawQuery('SELECT COUNT(*) FROM songs'),
      );
      if (count != null && count > 0) return;
      final data = await file.readAsString();
      if (data.isEmpty) {
        await file.delete();
        return;
      }
      final list = jsonDecode(data) as List<dynamic>;
      final rows = list
          .map(
            (e) => _toRow(
              Song.fromJson(_resolve(e as Map<String, dynamic>, docs)),
              docs,
            ),
          )
          .toList();
      await _db!.transaction((txn) async {
        final batch = txn.batch();
        for (final r in rows) {
          batch.insert(
            'songs',
            r,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
      await file.delete();
      Log.i('LibraryCache', '已从旧 JSON 缓存迁移 ${rows.length} 首歌曲');
    } catch (e) {
      // 迁移失败保留 JSON，下次启动重试
      Log.e('LibraryCache', 'JSON 迁移失败: $e');
    }
  }

  // ── Song ↔ 行映射 ──

  static const _pathKeys = ['path', 'coverUrl', 'lyricsPath'];

  static Map<String, Object?> _toRow(Song s, String docs) {
    final j = _relativize(s.toJson(), docs);
    return {
      'id': j['id'],
      'title': j['title'],
      'artist': j['artist'],
      'album': j['album'],
      'duration_ms': j['durationMs'],
      'color': j['color'],
      'has_lyrics': j['hasLyrics'] ? 1 : 0,
      'bpm': j['bpm'],
      'key': j['key'],
      'cover_url': j['coverUrl'],
      'path': j['path'],
      'stream_url': j['streamUrl'],
      'smb_path': j['smbPath'],
      'dav_path': j['davPath'],
      'strm_path': j['strmPath'],
      'strm_from_webdav': j['strmFromWebdav'] ? 1 : 0,
      'target_uri': j['targetUri'],
      'target_kind': j['targetKind'],
      'lyrics_path': j['lyricsPath'],
      'has_cover': j['hasCover'] ? 1 : 0,
      'duration_estimated': j['durationEstimated'] ? 1 : 0,
    };
  }

  static Song _fromRow(Map<String, Object?> row, String docs) {
    final j = <String, dynamic>{
      'id': row['id'],
      'title': row['title'],
      'artist': row['artist'],
      'album': row['album'],
      'durationMs': row['duration_ms'],
      'color': row['color'],
      'hasLyrics': row['has_lyrics'] == 1,
      'bpm': row['bpm'],
      'key': row['key'],
      'coverUrl': row['cover_url'],
      'path': row['path'],
      'streamUrl': row['stream_url'],
      'smbPath': row['smb_path'],
      'davPath': row['dav_path'],
      'strmPath': row['strm_path'],
      'strmFromWebdav': row['strm_from_webdav'] == 1,
      'targetUri': row['target_uri'],
      'targetKind': row['target_kind'],
      'lyricsPath': row['lyrics_path'],
      'hasCover': row['has_cover'] == 1,
      'durationEstimated': row['duration_estimated'] == 1,
    };
    return Song.fromJson(_resolve(j, docs));
  }

  /// 沙盒内绝对路径 → 相对路径（去掉 Documents 前缀）；
  /// 沙盒外路径（系统媒体库/ipod-library 等）原样保留。
  static Map<String, dynamic> _relativize(
    Map<String, dynamic> json,
    String docs,
  ) {
    for (final k in _pathKeys) {
      final v = json[k];
      if (v is String && v.startsWith('$docs/')) {
        json[k] = v.substring(docs.length + 1).replaceAll(RegExp(r'^/'), '');
      }
    }
    return json;
  }

  /// 相对路径 → 绝对路径（拼回当前 Documents 目录）。
  /// 兼容存量绝对路径数据：不以 '/' 开头且非 URL（ipod-library:// 等）
  /// 才视为相对路径，旧数据的失效绝对路径由 restoreCachedSongs 的
  /// 存在性清洗兜底。
  static Map<String, dynamic> _resolve(
    Map<String, dynamic> json,
    String docs,
  ) {
    for (final k in _pathKeys) {
      final v = json[k];
      if (v is String &&
          v.isNotEmpty &&
          !v.startsWith('/') &&
          !v.contains('://')) {
        json[k] = '$docs/$v';
      }
    }
    return json;
  }
}