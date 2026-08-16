//! 元数据标签写入（基于 lofty）
//!
//! 读取走 [`decoder::read_metadata`](crate::decoder::read_metadata)，
//! 本模块补齐写入能力：修改标题/歌手/专辑等常见字段并落盘。
//!
//! 支持格式取决于 lofty：MP3 (ID3v2)、FLAC (VorbisComment)、M4A/MP4 (ilst)、
//! OGG (VorbisComment)、WAV (RIFF INFO / ID3v2)、AIFF 等。
//!
//! ```no_run
//! use audio_core::tag::{write_tags, TagUpdate};
//! use std::path::Path;
//!
//! let update = TagUpdate {
//!     title: Some("新标题".into()),
//!     artist: Some("歌手".into()),
//!     ..Default::default()
//! };
//! write_tags(Path::new("/music/song.flac"), &update).unwrap();
//! ```
//!
//! 注意：写入会修改原文件，建议 UI 层先确认。字段为 `None` 表示不修改（非清除）。

use std::path::Path;

use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::*;
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem};

/// 标签更新请求（`None` = 保持原值不变）
#[derive(Debug, Clone, Default)]
pub struct TagUpdate {
    /// 标题
    pub title: Option<String>,
    /// 歌手
    pub artist: Option<String>,
    /// 专辑
    pub album: Option<String>,
    /// 专辑歌手
    pub album_artist: Option<String>,
    /// 流派
    pub genre: Option<String>,
    /// 备注
    pub comment: Option<String>,
    /// 曲目号
    pub track_number: Option<u32>,
    /// 总曲目数
    pub track_total: Option<u32>,
    /// 碟号
    pub disc_number: Option<u32>,
    /// 总碟数
    pub disc_total: Option<u32>,
}

impl TagUpdate {
    /// 是否所有字段都为空（无操作）
    pub fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.artist.is_none()
            && self.album.is_none()
            && self.album_artist.is_none()
            && self.genre.is_none()
            && self.comment.is_none()
            && self.track_number.is_none()
            && self.track_total.is_none()
            && self.disc_number.is_none()
            && self.disc_total.is_none()
    }
}

/// 将标签更新写入文件（原地修改）。
///
/// 文件无任何标签时，按容器格式创建主标签（如 MP3→ID3v2、FLAC→VorbisComment）。
/// 仅写入 `Some` 字段，其余保持原值。
pub fn write_tags(path: &Path, update: &TagUpdate) -> Result<(), String> {
    if update.is_empty() {
        return Ok(());
    }

    let mut tagged = lofty::read_from_path(path).map_err(|e| format!("打开文件失败: {e}"))?;

    // 无标签时按格式创建主标签
    if tagged.primary_tag_mut().is_none() && tagged.first_tag_mut().is_none() {
        let tag_type = tagged.file_type().primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
    }

    let tag = match tagged.primary_tag_mut() {
        Some(t) => t,
        None => tagged
            .first_tag_mut()
            .ok_or_else(|| "文件不支持标签".to_string())?,
    };

    if let Some(v) = &update.title {
        tag.set_title(v.clone());
    }
    if let Some(v) = &update.artist {
        tag.set_artist(v.clone());
    }
    if let Some(v) = &update.album {
        tag.set_album(v.clone());
    }
    if let Some(v) = &update.genre {
        tag.set_genre(v.clone());
    }
    if let Some(v) = &update.comment {
        tag.set_comment(v.clone());
    }
    if let Some(v) = update.track_number {
        tag.set_track(v);
    }
    if let Some(v) = update.track_total {
        tag.set_track_total(v);
    }
    if let Some(v) = update.disc_number {
        tag.set_disk(v);
    }
    if let Some(v) = update.disc_total {
        tag.set_disk_total(v);
    }
    // 专辑歌手不在 Accessor 通用接口中，按 ItemKey 写入
    if let Some(v) = &update.album_artist {
        tag.insert(TagItem::new(
            ItemKey::AlbumArtist,
            ItemValue::Text(v.clone()),
        ));
    }

    tagged
        .save_to_path(path, WriteOptions::default())
        .map_err(|e| format!("保存标签失败: {e}"))?;

    Ok(())
}

/// 读取文件的常见标签字段（写入前预览 / 回读验证用）
#[derive(Debug, Clone, Default)]
pub struct TagInfo {
    /// 标题
    pub title: Option<String>,
    /// 歌手
    pub artist: Option<String>,
    /// 专辑
    pub album: Option<String>,
    /// 专辑歌手
    pub album_artist: Option<String>,
    /// 流派
    pub genre: Option<String>,
    /// 曲目号
    pub track_number: Option<u32>,
}

/// 读取文件标签（优先主标签，退而任意标签）
pub fn read_tags(path: &Path) -> Result<TagInfo, String> {
    let tagged = lofty::read_from_path(path).map_err(|e| format!("打开文件失败: {e}"))?;
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(TagInfo::default());
    };

    Ok(TagInfo {
        title: tag.title().map(|s| s.to_string()),
        artist: tag.artist().map(|s| s.to_string()),
        album: tag.album().map(|s| s.to_string()),
        album_artist: tag.get_string(ItemKey::AlbumArtist).map(|s| s.to_string()),
        genre: tag.genre().map(|s| s.to_string()),
        track_number: tag.track(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 生成一个最小合法 WAV（RIFF），lofty 可读可写
    fn make_wav(path: &Path) {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 44100,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        for i in 0..4410 {
            let v =
                ((i as f32 / 44100.0 * 440.0 * 2.0 * std::f32::consts::PI).sin() * 10000.0) as i16;
            writer.write_sample(v).unwrap();
        }
        writer.finalize().unwrap();
    }

    #[test]
    fn write_then_read_roundtrip_wav() {
        let dir = std::env::temp_dir().join("wavelink_tag_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tag_test.wav");
        make_wav(&path);

        let update = TagUpdate {
            title: Some("测试标题".into()),
            artist: Some("测试歌手".into()),
            album: Some("测试专辑".into()),
            genre: Some("Electronic".into()),
            track_number: Some(3),
            track_total: Some(12),
            ..Default::default()
        };
        write_tags(&path, &update).expect("写入应成功");

        let info = read_tags(&path).expect("回读应成功");
        assert_eq!(info.title.as_deref(), Some("测试标题"));
        assert_eq!(info.artist.as_deref(), Some("测试歌手"));
        assert_eq!(info.album.as_deref(), Some("测试专辑"));
        assert_eq!(info.genre.as_deref(), Some("Electronic"));
        assert_eq!(info.track_number, Some(3));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn partial_update_preserves_others() {
        let dir = std::env::temp_dir().join("wavelink_tag_test2");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tag_test2.wav");
        make_wav(&path);

        write_tags(
            &path,
            &TagUpdate {
                title: Some("原标题".into()),
                artist: Some("原歌手".into()),
                ..Default::default()
            },
        )
        .unwrap();

        // 只改标题，歌手应保留
        write_tags(
            &path,
            &TagUpdate {
                title: Some("新标题".into()),
                ..Default::default()
            },
        )
        .unwrap();

        let info = read_tags(&path).unwrap();
        assert_eq!(info.title.as_deref(), Some("新标题"));
        assert_eq!(info.artist.as_deref(), Some("原歌手"), "未更新字段应保留");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn empty_update_is_noop() {
        let dir = std::env::temp_dir().join("wavelink_tag_test3");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tag_test3.wav");
        make_wav(&path);
        let before = std::fs::read(&path).unwrap();

        write_tags(&path, &TagUpdate::default()).unwrap();
        let after = std::fs::read(&path).unwrap();
        assert_eq!(before, after, "空更新不应修改文件");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn nonexistent_file_errors() {
        let result = write_tags(
            Path::new("/tmp/_wavelink_nonexistent_tag.wav"),
            &TagUpdate {
                title: Some("x".into()),
                ..Default::default()
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn read_no_tags_returns_default() {
        let dir = std::env::temp_dir().join("wavelink_tag_test4");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tag_test4.wav");
        make_wav(&path);
        let info = read_tags(&path).unwrap();
        assert!(info.title.is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
