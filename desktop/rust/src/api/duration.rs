//! 桌面端音频时长提取 FFI（扫描期回填 NAS/WebDAV 曲库时长，替代固定 1000kbps 粗估）
//!
//! 复用现有 lofty（cover.rs 已在用）+ SMB/WebDAV 读头能力：
//! - NAS：读文件头（smb_read_head，最多 head_limit 字节）→ lofty 内存探测
//! - WebDAV：读文件头（engine_read_webdav_range 的 head 模式）→ lofty 内存探测
//! 头部足以覆盖绝大多数无损/hi-res 格式的时长（写在容器头里）：
//! FLAC / DSF / DFF / WAV / ALAC(m4a) / APE / WV / AIFF，以及带 Xing/Info/LAME
//! 头的 MP3；少数需尾部页才能确定时长的格式（如 OGG/OPUS）探不到 → 返回 None，
//! 由 Dart 侧回退 estimateDuration（粗估）。

use flutter_rust_bridge::frb;

/// NAS 文件真实时长（秒）。读文件头经 lofty 内存探测；网络读失败或 lofty
/// 探不到（如 OGG 需尾部页）返回 None，由 Dart 侧回退 estimateDuration。
#[frb]
pub async fn get_nas_duration(path: String, head_limit: u64) -> Option<f64> {
    match crate::api::smb::smb_read_head(path, head_limit).await {
        Ok(data) => read_duration_from_memory(data),
        Err(_) => None,
    }
}

/// WebDAV 文件真实时长（秒）。读文件头（Range 请求）经 lofty 内存探测；
/// 网络读失败或 lofty 探不到返回 None，由 Dart 侧回退 estimateDuration。
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

/// 从内存字节探测真实时长（网络音源：读头部后经 lofty 内存解析）。
fn read_duration_from_memory(data: Vec<u8>) -> Option<f64> {
    let mut reader = std::io::Cursor::new(data);
    let tagged_file = lofty::probe::Probe::new(&mut reader)
        .guess_file_type()
        .ok()?
        .read()
        .ok()?;
    duration_of(&tagged_file)
}

/// 取 lofty 解析出的时长（秒）；无法判定（0）返回 None。
fn duration_of(tagged_file: &lofty::file::TaggedFile) -> Option<f64> {
    use lofty::file::AudioFile;
    let secs = tagged_file.properties().duration().as_secs_f64();
    if secs > 0.0 {
        Some(secs)
    } else {
        None
    }
}
