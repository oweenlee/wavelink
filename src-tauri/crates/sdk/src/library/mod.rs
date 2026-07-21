//! 曲库管理：标签读取、数据库、目录扫描
//!
//! 职责：
//! - `db` — SQLite 数据库定义与 CRUD
//! - `scanner` — 递归扫描目录，用 audio-core 读标签写入数据库

pub mod db;
pub mod editor;
pub mod playlist;
pub mod replaygain;
pub mod scanner;

pub use db::{AlbumBrief, LibraryDb, Track};
pub use editor::{edit_audio_tags, TagUpdate};
pub use replaygain::{analyze_loudness, gain_for_loudness};
pub use playlist::{export_playlist, export_playlist_with_meta, import_playlist, PlaylistEntry};
pub use scanner::{get_file_cover, Scanner, ScannerResult};
