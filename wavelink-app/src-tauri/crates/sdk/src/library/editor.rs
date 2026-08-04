use std::path::Path;

use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::read_from_path;
use lofty::tag::{ItemKey, ItemValue};

/// 单个字段的标签更新
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TagUpdate {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub track_number: Option<i32>,
    pub year: Option<i32>,
}

/// 编辑音频文件的标签，返回更新后的 Track 数据
pub fn edit_audio_tags(path: &str, update: &TagUpdate) -> Result<super::Track, String> {
    let p = Path::new(path);
    if !p.exists() {
        return Err(format!("文件不存在: {path}"));
    }

    // 读取
    let mut tagged = read_from_path(p).map_err(|e| format!("读取标签失败: {e}"))?;

    // 获取主标签
    let tag = if let Some(t) = tagged.primary_tag_mut() {
        t
    } else if let Some(t) = tagged.first_tag_mut() {
        t
    } else {
        return Err("无法获取标签".to_string());
    };

    // 应用更新
    fn apply(tag: &mut lofty::tag::Tag, key: ItemKey, val: &Option<String>) {
        if let Some(v) = val {
            tag.take(key).for_each(drop);
            tag.insert_text(key, v.clone());
        }
    }

    apply(tag, ItemKey::TrackTitle, &update.title);
    apply(tag, ItemKey::TrackArtist, &update.artist);
    apply(tag, ItemKey::AlbumTitle, &update.album);
    apply(tag, ItemKey::Genre, &update.genre);

    if let Some(n) = update.track_number {
        tag.take(ItemKey::TrackNumber).for_each(drop);
        let val = lofty::tag::TagItem::new(ItemKey::TrackNumber, ItemValue::Text(n.to_string()));
        tag.insert(val);
    }
    if let Some(y) = update.year {
        tag.take(ItemKey::Year).for_each(drop);
        let val = lofty::tag::TagItem::new(ItemKey::Year, ItemValue::Text(y.to_string()));
        tag.insert(val);
    }

    // 写回文件
    let opts = WriteOptions::default();
    tagged.save_to_path(path, opts).map_err(|e| format!("保存标签失败: {e}"))?;

    // 重新扫描以获取最新数据
    let scanned = super::Scanner::scan_file(p)
        .map_err(|e| format!("重新扫描失败: {e}"))?
        .ok_or_else(|| "重新扫描后无数据".to_string())?;

    Ok(scanned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_edit_nonexistent_file() {
        // 至少验证错误路径
        let result = edit_audio_tags("/tmp/__nonexistent_audio_file__.mp3", &TagUpdate {
            title: Some("Test".into()),
            artist: None,
            album: None,
            genre: None,
            track_number: None,
            year: None,
        });
        assert!(result.is_err(), "不存在的文件应返回 Err");
        let err = result.unwrap_err();
        assert!(err.contains("不存在") || err.contains("exist"), "错误信息应提示文件不存在: {err}");
    }
}
