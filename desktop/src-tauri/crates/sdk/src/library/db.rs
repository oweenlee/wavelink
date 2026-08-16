use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, Result as SqlResult};

/// 专辑摘要（用于封面网格浏览）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AlbumBrief {
    pub artist: String,
    pub album: String,
    pub first_track_id: i64,
    pub first_track_path: String,
    pub year: Option<i32>,
}

/// 曲目记录
#[derive(Debug, Clone)]
#[derive(serde::Serialize, serde::Deserialize)]
pub struct Track {
    pub id: i64,
    pub path: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<i32>,
    pub disc_number: Option<i32>,
    pub year: Option<i32>,
    pub genre: Option<String>,
    pub duration: Option<f64>,
    pub sample_rate: Option<i32>,
    pub channels: Option<i32>,
    pub format: Option<String>,
    pub file_size: Option<i64>,
    pub file_modified: Option<i64>,
    pub date_added: i64,
    pub play_count: i32,
    pub last_played: Option<i64>,
    pub rating: i32,
    pub missing: bool,
    #[serde(skip)]
    pub cover_base64: Option<String>,
    /// ReplayGain 曲目增益 (dB)
    pub track_gain: Option<f64>,
}

/// 曲库数据库
pub struct LibraryDb {
    conn: Connection,
}

/// 用于列表 / 搜索的列：排除体积较大的 cover 列，避免每次查询把整张封面读进内存
const LIST_COLUMNS: &str = "id, path, title, artist, album, album_artist, \
    track_number, disc_number, year, genre, duration, \
    sample_rate, channels, format, file_size, file_modified, \
    date_added, play_count, last_played, rating, missing, track_gain";

/// 完整列（含 cover），列序必须与 row_to_track 的位置映射一致
const FULL_COLUMNS: &str = "id, path, title, artist, album, album_artist, \
    track_number, disc_number, year, genre, duration, \
    sample_rate, channels, format, file_size, file_modified, \
    date_added, play_count, last_played, rating, missing, cover, track_gain";

impl LibraryDb {
    /// 打开（或创建）数据库
    pub fn open(path: &Path) -> SqlResult<Self> {
        let conn = Connection::open(path)?;
        // 多个连接会并发写同一个库（扫描 / 监控 / 分析）。
        // 设置 busy_timeout 后, 写冲突会等待而不是立即 SQLITE_BUSY 失败丢歌
        conn.busy_timeout(Duration::from_secs(10))?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        let db = LibraryDb { conn };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> SqlResult<()> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS tracks (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                path        TEXT UNIQUE NOT NULL,
                title       TEXT,
                artist      TEXT,
                album       TEXT,
                album_artist TEXT,
                track_number INTEGER,
                disc_number INTEGER,
                year        INTEGER,
                genre       TEXT,
                duration    REAL,
                sample_rate INTEGER,
                channels    INTEGER,
                format      TEXT,
                file_size   INTEGER,
                file_modified INTEGER,
                date_added  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
                play_count  INTEGER NOT NULL DEFAULT 0,
                last_played INTEGER,
                rating      INTEGER NOT NULL DEFAULT 0,
                missing     INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS analysis_results (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                track_id    INTEGER UNIQUE NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                bpm         REAL,
                key         TEXT,
                energy      REAL,
                last_analyzed INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_tracks_path ON tracks(path);
            CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
            CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
            CREATE TABLE IF NOT EXISTS scan_folders (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT UNIQUE NOT NULL,
                label TEXT
            );",
        )?;
        // 旧的数据库可能缺少 cover 列
        self.conn.execute_batch(
            "ALTER TABLE tracks ADD COLUMN cover TEXT;",
        ).ok();
        self.conn.execute_batch(
            "ALTER TABLE tracks ADD COLUMN track_gain REAL;",
        ).ok();
        Ok(())
    }

    /// 清空所有数据（删除并重建所有表）
    pub fn reset_database(&self) -> SqlResult<()> {
        self.conn.execute_batch(
            "DROP TABLE IF EXISTS scan_folders;
             DROP TABLE IF EXISTS analysis_results;
             DROP TABLE IF EXISTS tracks;",
        )?;
        self.migrate()
    }

    /// 插入或更新曲目（按 path 去重）
    ///
    /// 首次插入时会写入 play_count / rating / date_added / last_played；
    /// 后续更新时保留已有统计数据（只覆写标签/文件信息）。
    pub fn upsert_track(&self, t: &Track) -> SqlResult<i64> {
        self.conn.execute(
            "INSERT INTO tracks (path, title, artist, album, album_artist,
                track_number, disc_number, year, genre, duration,
                sample_rate, channels, format, file_size, file_modified, cover,
                track_gain, play_count, rating, date_added, last_played)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,
                ?18,?19,?20,?21)
            ON CONFLICT(path) DO UPDATE SET
                title=excluded.title, artist=excluded.artist, album=excluded.album,
                album_artist=excluded.album_artist, track_number=excluded.track_number,
                disc_number=excluded.disc_number, year=excluded.year, genre=excluded.genre,
                duration=excluded.duration, sample_rate=excluded.sample_rate,
                channels=excluded.channels, format=excluded.format,
                file_size=excluded.file_size, file_modified=excluded.file_modified,
                cover=excluded.cover, missing=0, track_gain=excluded.track_gain",
            params![
                t.path, t.title, t.artist, t.album, t.album_artist,
                t.track_number, t.disc_number, t.year, t.genre, t.duration,
                t.sample_rate, t.channels, t.format, t.file_size, t.file_modified,
                t.cover_base64, t.track_gain,
                t.play_count, t.rating, t.date_added, t.last_played,
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 标记已不存在的文件
    pub fn mark_missing(&self, path: &str) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE tracks SET missing=1 WHERE path=?1",
            params![path],
        )?;
        Ok(())
    }

    /// 清空 missing 标记（扫描前调用）
    pub fn reset_missing_flags(&self) -> SqlResult<()> {
        self.conn.execute("UPDATE tracks SET missing=0", [])?;
        Ok(())
    }

    /// 扫描完成后，missing 仍为 1 的路径即为被删除的文件
    pub fn remove_missing_tracks(&self) -> SqlResult<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT path FROM tracks WHERE missing=1",
        )?;
        let paths: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        self.conn.execute("DELETE FROM tracks WHERE missing=1", [])?;
        Ok(paths)
    }

    /// 删除单条曲目记录
    pub fn remove_track(&self, track_id: i64) -> SqlResult<()> {
        self.conn
            .execute("DELETE FROM tracks WHERE id=?1", [track_id])?;
        Ok(())
    }

    /// 添加扫描文件夹
    pub fn add_folder(&self, path: &str) -> SqlResult<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO scan_folders (path) VALUES (?1)",
            params![path],
        )?;
        Ok(())
    }

    /// 删除扫描文件夹及其所有曲目
    pub fn remove_folder(&self, path: &str) -> SqlResult<Vec<String>> {
        let prefix = format!("{}/", path.trim_end_matches('/'));
        let mut stmt = self.conn.prepare(
            "SELECT path FROM tracks WHERE path LIKE ?1 OR path = ?2",
        )?;
        let removed: Vec<String> = stmt
            .query_map(params![format!("{prefix}%"), path], |r| r.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        self.conn.execute(
            "DELETE FROM tracks WHERE path LIKE ?1 OR path = ?2",
            params![format!("{prefix}%"), path],
        )?;
        self.conn.execute(
            "DELETE FROM scan_folders WHERE path=?1",
            params![path],
        )?;
        Ok(removed)
    }

    /// 列出所有扫描文件夹
    pub fn list_folders(&self) -> SqlResult<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT path FROM scan_folders ORDER BY path",
        )?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        rows.collect()
    }

    /// 搜索曲目
    pub fn search(&self, keyword: &str, limit: i64, offset: i64) -> SqlResult<Vec<Track>> {
        let pattern = format!("%{}%", keyword);
        let mut stmt = self.conn.prepare(
            &format!("SELECT {LIST_COLUMNS} FROM tracks
             WHERE missing=0
               AND (title LIKE ?1 OR artist LIKE ?1 OR album LIKE ?1)
             ORDER BY artist, album, track_number
             LIMIT ?2 OFFSET ?3"),
        )?;
        let rows = stmt.query_map(params![pattern, limit, offset], Self::row_to_track_light)?;
        rows.collect()
    }

    /// 获取所有艺术家（用于浏览）
    pub fn artists(&self) -> SqlResult<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT artist FROM tracks WHERE missing=0 AND artist IS NOT NULL ORDER BY artist",
        )?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        rows.collect()
    }

    /// 获取某个艺术家的专辑
    pub fn albums_by_artist(&self, artist: &str) -> SqlResult<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT album FROM tracks WHERE artist=?1 AND missing=0 AND album IS NOT NULL ORDER BY album",
        )?;
        let rows = stmt.query_map(params![artist], |r| r.get(0))?;
        rows.collect()
    }

    /// 获取所有专辑（含艺术家、第一首曲目 ID 和路径、年份），按艺术家+专辑排序
    pub fn all_albums(&self) -> SqlResult<Vec<AlbumBrief>> {
        let mut stmt = self.conn.prepare(
            "SELECT t1.artist, t1.album, t1.id, t1.path, t1.year
             FROM tracks t1
             INNER JOIN (
                 SELECT artist, album, MIN(id) AS first_id
                 FROM tracks
                 WHERE missing=0 AND artist IS NOT NULL AND album IS NOT NULL
                 GROUP BY artist, album
             ) t2 ON t1.id = t2.first_id
             ORDER BY t1.artist, t1.album",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(AlbumBrief {
                artist: row.get(0)?,
                album: row.get(1)?,
                first_track_id: row.get(2)?,
                first_track_path: row.get(3)?,
                year: row.get(4)?,
            })
        })?;
        rows.collect()
    }

    /// 获取某个专辑的曲目
    pub fn tracks_by_album(&self, artist: &str, album: &str) -> SqlResult<Vec<Track>> {
        let mut stmt = self.conn.prepare(
            &format!("SELECT {LIST_COLUMNS} FROM tracks
             WHERE artist=?1 AND album=?2 AND missing=0
             ORDER BY disc_number, track_number"),
        )?;
        let rows = stmt.query_map(params![artist, album], Self::row_to_track_light)?;
        rows.collect()
    }

    /// 所有曲目（不含 missing），支持按列排序（白名单防 SQL 注入）
    pub fn all_tracks(&self, limit: i64, offset: i64, sort_by: Option<&str>) -> SqlResult<Vec<Track>> {
        let order = match sort_by {
            Some("title") => "title COLLATE NOCASE, artist COLLATE NOCASE, album COLLATE NOCASE",
            Some("album") => "album COLLATE NOCASE, disc_number, track_number",
            Some("duration") => "duration, artist COLLATE NOCASE, album COLLATE NOCASE",
            // 默认按艺术家/专辑/音轨序
            _ => "artist COLLATE NOCASE, album COLLATE NOCASE, track_number",
        };
        let mut stmt = self.conn.prepare(
            &format!("SELECT {LIST_COLUMNS} FROM tracks WHERE missing=0 ORDER BY {order} LIMIT ?1 OFFSET ?2"),
        )?;
        let rows = stmt.query_map(params![limit, offset], Self::row_to_track_light)?;
        rows.collect()
    }

    /// 曲目总数
    pub fn track_count(&self) -> SqlResult<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM tracks WHERE missing=0", [], |r| r.get(0))
    }

    /// 列表 / 搜索用的轻量行映射（不含 cover 列，cover_base64 置空）
    fn row_to_track_light(row: &rusqlite::Row) -> rusqlite::Result<Track> {
        Ok(Track {
            id: row.get(0)?,
            path: row.get(1)?,
            title: row.get(2)?,
            artist: row.get(3)?,
            album: row.get(4)?,
            album_artist: row.get(5)?,
            track_number: row.get(6)?,
            disc_number: row.get(7)?,
            year: row.get(8)?,
            genre: row.get(9)?,
            duration: row.get(10)?,
            sample_rate: row.get(11)?,
            channels: row.get(12)?,
            format: row.get(13)?,
            file_size: row.get(14)?,
            file_modified: row.get(15)?,
            date_added: row.get(16)?,
            play_count: row.get(17)?,
            last_played: row.get(18)?,
            rating: row.get(19)?,
            missing: row.get::<_, i32>(20)? != 0,
            cover_base64: None,
            track_gain: row.get(21)?,
        })
    }

    fn row_to_track(row: &rusqlite::Row) -> rusqlite::Result<Track> {
        Ok(Track {
            id: row.get(0)?,
            path: row.get(1)?,
            title: row.get(2)?,
            artist: row.get(3)?,
            album: row.get(4)?,
            album_artist: row.get(5)?,
            track_number: row.get(6)?,
            disc_number: row.get(7)?,
            year: row.get(8)?,
            genre: row.get(9)?,
            duration: row.get(10)?,
            sample_rate: row.get(11)?,
            channels: row.get(12)?,
            format: row.get(13)?,
            file_size: row.get(14)?,
            file_modified: row.get(15)?,
            date_added: row.get(16)?,
            play_count: row.get(17)?,
            last_played: row.get(18)?,
            rating: row.get(19)?,
            missing: row.get::<_, i32>(20)? != 0,
            cover_base64: row.get(21)?,
            track_gain: row.get(22)?,
        })
    }

    /// 增加播放次数
    pub fn increment_play_count(&self, id: i64) -> SqlResult<()> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
        self.conn.execute(
            "UPDATE tracks SET play_count = play_count + 1, last_played = ?1 WHERE id = ?2",
            params![now, id],
        )?;
        Ok(())
    }

    /// 设置曲目 ReplayGain 增益
    pub fn set_track_gain(&self, path: &str, gain: f64) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE tracks SET track_gain=?1 WHERE path=?2",
            params![gain, path],
        )?;
        Ok(())
    }

    /// 保存分析结果
    pub fn set_analysis(&self, track_id: i64, bpm: Option<f32>, key: Option<&str>, energy: Option<f32>) -> SqlResult<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        self.conn.execute(
            "INSERT INTO analysis_results (track_id, bpm, key, energy, last_analyzed)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(track_id) DO UPDATE SET
                 bpm=excluded.bpm, key=excluded.key,
                 energy=excluded.energy, last_analyzed=excluded.last_analyzed",
            params![track_id, bpm, key, energy, now],
        )?;
        Ok(())
    }

    /// 获取分析结果
    pub fn get_analysis(&self, track_id: i64) -> SqlResult<Option<audio_core::analysis::AnalysisResult>> {
        let mut stmt = self.conn.prepare(
            "SELECT bpm, key, energy FROM analysis_results WHERE track_id=?1",
        )?;
        let mut rows = stmt.query_map(params![track_id], |row| {
            Ok(audio_core::analysis::AnalysisResult {
                bpm: row.get(0)?,
                key: row.get(1)?,
                energy: row.get(2)?,
                bpm_confidence: None,
                key_confidence: None,
            })
        })?;
        match rows.next() {
            Some(Ok(r)) => Ok(Some(r)),
            _ => Ok(None),
        }
    }

    /// 批量获取分析结果
    pub fn get_analyses(&self, track_ids: &[i64]) -> SqlResult<std::collections::HashMap<i64, audio_core::analysis::AnalysisResult>> {
        if track_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }
        let placeholders: Vec<String> = track_ids.iter().map(|_| "?".to_string()).collect();
        let sql = format!(
            "SELECT track_id, bpm, key, energy FROM analysis_results WHERE track_id IN ({})",
            placeholders.join(",")
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = track_ids
            .iter()
            .map(|id| id as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt.query_map(params.as_slice(), |row| {
            let track_id: i64 = row.get(0)?;
            let result = audio_core::analysis::AnalysisResult {
                bpm: row.get(1)?,
                key: row.get(2)?,
                energy: row.get(3)?,
                bpm_confidence: None,
                key_confidence: None,
            };
            Ok((track_id, result))
        })?;
        let mut map = std::collections::HashMap::new();
        for (id, result) in rows.flatten() {
            map.insert(id, result);
        }
        Ok(map)
    }

    /// 按文件路径查找曲目
    pub fn get_track_by_path(&self, path: &str) -> SqlResult<Option<Track>> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {FULL_COLUMNS} FROM tracks WHERE path=?1"
        ))?;
        let mut rows = stmt.query_map(params![path], Self::row_to_track)?;
        match rows.next() {
            Some(r) => Ok(Some(r?)),
            None => Ok(None),
        }
    }

    /// 获取曲目封面（base64 字符串）
    pub fn get_cover(&self, track_id: i64) -> SqlResult<Option<String>> {
        match self.conn.query_row(
            "SELECT cover FROM tracks WHERE id=?1 AND cover IS NOT NULL",
            params![track_id],
            |row| row.get(0),
        ) {
            Ok(val) => Ok(val),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_in_memory_db() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        let db = LibraryDb { conn };
        db.migrate().unwrap();

        let t = Track {
            id: 0,
            path: "/test/song.flac".into(),
            title: Some("Test Song".into()),
            artist: Some("Test Artist".into()),
            album: Some("Test Album".into()),
            album_artist: None,
            track_number: Some(1),
            disc_number: Some(1),
            year: Some(2024),
            genre: Some("Test".into()),
            duration: Some(180.0),
            sample_rate: Some(44100),
            channels: Some(2),
            format: Some("flac".into()),
            file_size: Some(12345),
            file_modified: Some(1700000000),
            date_added: 1700000000,
            play_count: 0,
            last_played: None,
            rating: 0,
            missing: false,
            cover_base64: None,
            track_gain: None,
        };
        db.upsert_track(&t).unwrap();
        assert_eq!(db.track_count().unwrap(), 1);

        let results = db.search("Test", 10, 0).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title.as_deref(), Some("Test Song"));
    }

    #[test]
    fn test_upsert_and_search() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        let db = LibraryDb { conn };
        db.migrate().unwrap();
        let t = Track {
            id: 0, path: "/a/b.mp3".into(), title: Some("Song Title".into()),
            artist: Some("Artist".into()), album: Some("Album".into()),
            album_artist: None, track_number: Some(1), disc_number: None,
            year: Some(2024), genre: Some("Rock".into()),
            duration: Some(180.0), sample_rate: Some(44100), channels: Some(2),
            format: Some("mp3".into()), file_size: Some(999), file_modified: None,
            date_added: 1000, play_count: 0, last_played: None, rating: 0,
            missing: false, cover_base64: None, track_gain: None,
        };
        db.upsert_track(&t).unwrap();
        assert_eq!(db.track_count().unwrap(), 1);

        let results = db.search("Song", 10, 0).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title.as_deref(), Some("Song Title"));
        assert_eq!(results[0].artist.as_deref(), Some("Artist"));
    }

    #[test]
    fn test_search_no_match() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        let db = LibraryDb { conn };
        db.migrate().unwrap();
        let t = Track { id: 0, path: "/x.mp3".into(), title: Some("Unique".into()),
            artist: Some("A".into()), album: None, album_artist: None,
            track_number: None, disc_number: None, year: None, genre: None,
            duration: None, sample_rate: None, channels: None, format: None,
            file_size: None, file_modified: None, date_added: 0, play_count: 0,
            last_played: None, rating: 0, missing: false, cover_base64: None, track_gain: None,
        };
        db.upsert_track(&t).unwrap();
        let results = db.search("NonExistent", 10, 0).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_artists_and_albums() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        let db = LibraryDb { conn };
        db.migrate().unwrap();
        for i in 0..3 {
            let t = Track { id: 0, path: format!("/{i}.mp3"), title: Some(format!("Song {i}")),
                artist: Some("TestArtist".into()), album: Some("TestAlbum".into()),
                album_artist: None, track_number: Some(i+1), disc_number: None,
                year: None, genre: None, duration: None, sample_rate: None,
                channels: None, format: None, file_size: None, file_modified: None,
                date_added: i as i64, play_count: 0, last_played: None, rating: 0,
                missing: false, cover_base64: None, track_gain: None,
            };
            db.upsert_track(&t).unwrap();
        }
        let artists = db.artists().unwrap();
        assert!(artists.contains(&"TestArtist".to_string()));
        let albums = db.albums_by_artist("TestArtist").unwrap();
        assert!(albums.contains(&"TestAlbum".to_string()));
    }

    #[test]
    fn test_remove_track() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        let db = LibraryDb { conn };
        db.migrate().unwrap();
        let t = Track { id: 0, path: "/r.mp3".into(), title: Some("Remove Me".into()),
            artist: Some("A".into()), album: None, album_artist: None,
            track_number: None, disc_number: None, year: None, genre: None,
            duration: None, sample_rate: None, channels: None, format: None,
            file_size: Some(1), file_modified: None, date_added: 0, play_count: 0,
            last_played: None, rating: 0, missing: false, cover_base64: None, track_gain: None,
        };
        let id = db.upsert_track(&t).unwrap();
        assert_eq!(db.track_count().unwrap(), 1);
        db.remove_track(id).unwrap();
        assert_eq!(db.track_count().unwrap(), 0);
    }
}
