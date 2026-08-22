//! 桌面端音频标签/时长提取 FFI（扫描期回填 NAS/WebDAV 曲库元数据与时长，
//! 替代固定 1000kbps 粗估与「全挤在一张 NAS Music 专辑」的占位体验）
//!
//! 复用现有 lofty（cover.rs 已在用）+ SMB/WebDAV 读头能力：
//! - NAS：读文件头（smb_read_head，最多 head_limit 字节）→ lofty 内存探测
//! - WebDAV：读文件头（engine_read_webdav_range 的 head 模式）→ lofty 内存探测
//! 头部足以覆盖绝大多数无损/hi-res 格式（FLAC/DSF/DFF/WAV/ALAC/APE/WV/AIFF，
//! 以及带 Xing/Info/LAME 头的 MP3）；少数需尾部页才能确定时长的格式（如
//! OGG/OPUS）探不到 → 由 Dart 侧回退文件名解析 + estimateDuration（粗估）。
//!
//! 与封面提取解耦：封面链路失败（无内嵌图 / 网络抖动）不影响专辑/艺术家
//! 回填——mobile 的遗憾点之一，桌面端从扫描期就一次读头把 tags 拿全。

use flutter_rust_bridge::frb;

/// 扫描期头部探测结果（标题/艺人/专辑/音轨号/时长，可为 None）。
pub struct HeadMetadataDto {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub track_number: Option<u32>,
    pub duration_secs: f64,
}

/// 读取音频头部并解析 tags + 时长（路径版本）。
fn read_metadata_from_memory(data: &[u8]) -> Option<HeadMetadataDto> {
    use lofty::file::{AudioFile, TaggedFileExt};
    use lofty::tag::Accessor;

    let mut reader = std::io::Cursor::new(data);
    let tagged = lofty::probe::Probe::new(&mut reader)
        .guess_file_type()
        .ok()?
        .read()
        .ok()?;
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
    let secs = tagged.properties().duration().as_secs_f64();
    // 整头部都解析不出来有意义内容（如纯 .lrc 被误扫）→ 返回 None
    // 交 Dart 侧回退文件名规则；时长/标签都空时不做回填。
    let title = tag.and_then(|t| t.title().map(|s| s.to_string()));
    let artist = tag.and_then(|t| t.artist().map(|s| s.to_string()));
    let album = tag.and_then(|t| t.album().map(|s| s.to_string()));
    let track = tag.and_then(|t| t.track());
    if title.is_none() && artist.is_none() && album.is_none() && secs <= 0.0 {
        return None;
    }
    Some(HeadMetadataDto {
        title,
        artist,
        album,
        track_number: track,
        duration_secs: if secs > 0.0 { secs } else { 0.0 },
    })
}

/// NAS 文件头部元数据（tags + 时长）。读头经 lofty 内存探测；网络读失败
/// 或 lofty 探不到返回 None，由 Dart 侧回退文件名解析 + estimateDuration。
#[frb]
pub async fn get_nas_metadata(path: String, head_limit: u64) -> Option<HeadMetadataDto> {
    match crate::api::smb::smb_read_head(path, head_limit).await {
        Ok(data) => read_metadata_from_memory(&data),
        Err(_) => None,
    }
}

/// WebDAV 文件头部元数据（tags + 时长）。语义与 [get_nas_metadata] 一致。
#[frb]
pub async fn get_webdav_metadata(
    url: String,
    username: String,
    password: String,
    head_limit: u64,
) -> Option<HeadMetadataDto> {
    match crate::api::webdav::engine_read_webdav_range(url, username, password, head_limit, false)
        .await
    {
        Ok(data) => read_metadata_from_memory(&data),
        Err(_) => None,
    }
}

/// NAS 文件真实时长（秒）。读文件头经 lofty 内存探测；网络读失败或 lofty
/// 探不到（如 OGG 需尾部页）返回 None，由 Dart 侧回退 estimateDuration。
///
/// 已被 [get_nas_metadata]（tags+时长一体）取代；保留仅为过渡兼容，
/// 新代码请用 metadata 版本（一次读头同时拿全标签与时长）。
#[frb]
pub async fn get_nas_duration(path: String, head_limit: u64) -> Option<f64> {
    match crate::api::smb::smb_read_head(path, head_limit).await {
        Ok(data) => read_duration_from_memory(data),
        Err(_) => None,
    }
}

/// WebDAV 文件真实时长（秒）；同 [get_nas_duration] 为过渡兼容接口。
#[frb]
pub async fn get_webdav_duration(
    url: String,
    username: String,
    password: String,
    head_limit: u64,
) -> Option<f64> {
    match crate::api::webdav::engine_read_webdav_range(url, username, password, head_limit, false)
        .await
    {
        Ok(data) => read_duration_from_memory(data),
        Err(_) => None,
    }
}

/// 从内存字节探测真实时长（过渡兼容：metadata 版本的时长子集）。
fn read_duration_from_memory(data: Vec<u8>) -> Option<f64> {
    read_metadata_from_memory(&data).map(|m| m.duration_secs).filter(|s| *s > 0.0)
}