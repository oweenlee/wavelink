import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/track.dart';

/// 曲库 SQLite 持久化层（桌面端）。
///
/// 为什么不用纯 JSON：整表 JSON 直接写最终文件，进程在写入中途被杀死会截断，
/// 下次启动读到损坏文件 → 曲库静默清空。SQLite 的事务 + WAL 把「写入一半」
/// 变成原子操作（要么整批生效、要么回滚），彻底消除该风险；同时增量重扫
/// 只需 upsert / delete 差异行，无需每次重写整张表。
///
/// 设计要点（与 mobile 对齐）：
/// - 以 [Track.id] 为主键，扫描结果按 id upsert（幂等，可重复扫描）。
/// - 本地文件夹按路径前缀整段替换（覆盖新增/删除）；网络音源按来源差集清理。
/// - 全部写操作包在单事务内，崩溃不半成品。
class TrackRepository {
  TrackRepository._();

  /// 数据库 schema 版本。**改表结构时必须 +1**，并在 [_onUpgrade] 里补
  /// 对应迁移语句（onCreate 建的是最新结构，老库走 onUpgrade 逐级升级）。
  /// 不加迁移直接改 onCreate = 老用户升级后曲库被当作损坏丢弃、静默清空。
  static const int dbVersion = 1;

  /// 逐级迁移：switch 不 break，保证跨多版本的老库（如 v1 → v3）依次
  /// 应用每一步迁移，与 onCreate 的最终结构对齐。
  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    // 示例（未来 v2 加列时）：
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE tracks ADD COLUMN genre TEXT');
    // }
  }

  static Database? _db;
  static Future<Database>? _dbFuture;
  static bool _initialized = false;

  /// 初始化后端：桌面（mac/win/linux）需先启动 FFI；移动端走原生通道。
  /// 幂等，可重复调用。
  static Future<void> init() async {
    if (_initialized) return;
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _initialized = true;
  }

  /// 打开数据库。用 future 缓存避免并发调用时双 openDatabase 竞态
  /// （`_db ??=` 在两个 await 之间仍为 null，会重复建连接）。
  static Future<Database> get _database =>
      _dbFuture ??= _openDatabase();

  static Future<Database> _openDatabase() async {
    await init();
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _db = await openDatabase(
      p.join(dir.path, 'wavelink_library.db'),
      version: dbVersion,
      onUpgrade: _onUpgrade,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT,
            filePath TEXT,
            lyricsPath TEXT,
            fallbackDurationMs INTEGER NOT NULL,
            source TEXT NOT NULL,
            remotePath TEXT,
            streamUrl TEXT,
            coverUrl TEXT,
            durationHintMs INTEGER,
            durationEstimated INTEGER NOT NULL DEFAULT 0,
            fileSize INTEGER,
            strmPath TEXT,
            strmFromWebdav INTEGER NOT NULL DEFAULT 0,
            targetUri TEXT,
            targetKind TEXT
          )
        ''');
      },
    );
    return _db!;
  }

  /// 转义 LIKE 模式里的通配符（% _ \），避免本地文件夹路径含这些字符时误匹配。
  static String _escapeLike(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// 启动恢复：读回全部曲目（网络音源靠此跨重启存活）。
  /// 失败向上抛异常，由调用方（PlayerController.init）兜底为空库并上报——
  /// 本层不再静默吞错（曾因 debugPrint 吞掉导致曲库静默清空且用户无感知）。
  static Future<List<Track>> getAll() async {
    final db = await _database;
    final rows = await db.query('tracks');
    return rows.map(Track.fromMap).toList();
  }

  /// 增量同步一次扫描结果到曲库。
  ///
  /// - [localPrefix] 非空（本地文件夹）：删除该前缀下本地曲目再插入扫描结果，
  ///   天然覆盖「新增」与「删除」。
  /// - [source] 非空（网络音源）：删除该来源不在 [scanned] 内的曲目，
  ///   清理服务器/共享上已移除的曲目。
  /// - 二者皆空则仅 upsert（兜底）。
  /// 全部在单事务内完成（原子）。失败向上抛，由调用方决定如何提示用户。
  static Future<void> syncScan(
    List<Track> scanned, {
    TrackSource? source,
    String? localPrefix,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      if (localPrefix != null) {
        await txn.delete(
          'tracks',
          where: 'source = ? AND filePath LIKE ? ESCAPE ?',
          whereArgs: [TrackSource.local.name, '${_escapeLike(localPrefix)}/%', r'\'],
        );
      } else if (source != null) {
        final ids = scanned.map((t) => t.id).toList();
        if (ids.isEmpty) {
          await txn.delete(
            'tracks',
            where: 'source = ?',
            whereArgs: [source.name],
          );
        } else {
          final ph = List.filled(ids.length, '?').join(',');
          await txn.delete(
            'tracks',
            where: 'source = ? AND id NOT IN ($ph)',
            whereArgs: [source.name, ...ids],
          );
        }
      }
      final batch = txn.batch();
      for (final t in scanned) {
        batch.insert(
          'tracks',
          t.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// 更新单曲封面缓存路径（封面提取完成后写回，供跨重启持久）。
  static Future<void> updateCoverUrl(String id, String? coverUrl) async {
    final db = await _database;
    await db.update(
      'tracks',
      {'coverUrl': coverUrl},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 移除某本地文件夹下全部曲目（UI 移除文件夹时调用）。失败向上抛。
  static Future<void> deleteLocalUnder(String prefix) async {
    final db = await _database;
    await db.delete(
      'tracks',
      where: 'source = ? AND filePath LIKE ? ESCAPE ?',
      whereArgs: [TrackSource.local.name, '${_escapeLike(prefix)}/%', r'\'],
    );
  }

  /// 清空整库（侧栏「清空全部数据」时调用）。失败向上抛。
  static Future<void> clear() async {
    final db = await _database;
    await db.delete('tracks');
  }

  /// 释放数据库连接（进程退出时调用，一般无需手动）。
  static Future<void> close() async {
    await _db?.close();
    _db = null;
    _dbFuture = null;
    _initialized = false;
  }
}
