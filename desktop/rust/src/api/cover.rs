//! 桌面端封面提取 FFI（镜像 mobile `api::metadata::get_cover_bytes`）
//!
//! 本地音频文件的内嵌封面提取：优先用 audio-core 的 `read_cover`
//! （lofty 主标签首图 + MKV/WebM 附件回退），失败再用 lofty 遍历全部
//! 标签/图片兜底。返回 JPEG/PNG/WEBP 原始字节，由 Dart 侧落盘到本地
//! 缓存目录并以 `Image.file` 渲染（对齐 mobile 的「封面为本地缓存文件」策略）。

use std::path::Path;

use flutter_rust_bridge::frb;

/// 读取音频文件内嵌封面图（原始字节）。无封面返回 Err。
#[frb]
pub fn get_cover_bytes(path: String) -> Result<Vec<u8>, String> {
    let p = Path::new(&path);
    if let Ok(data) = audio_core::decoder::read_cover(p) {
        return Ok(data);
    }
    extract_cover_lofty(p)
}

/// 用 lofty 遍历所有标签图片兜底提取封面（read_cover 漏掉的非首图/次标签场景）。
fn extract_cover_lofty(path: &Path) -> Result<Vec<u8>, String> {
    use lofty::file::TaggedFileExt;

    let tagged_file = lofty::read_from_path(path)
        .map_err(|e| format!("lofty 读取失败: {e}"))?;

    // 先取封面/媒体类图片（优先 CoverFront / Media）
    for tag in tagged_file.tags() {
        for pic in tag.pictures() {
            let pic_type = pic.pic_type();
            if matches!(
                pic_type,
                lofty::picture::PictureType::CoverFront
                    | lofty::picture::PictureType::Media
            ) {
                let data = pic.data();
                if !data.is_empty() {
                    return Ok(data.to_vec());
                }
            }
        }
    }
    // 没有封面类图片，取任意图片
    for tag in tagged_file.tags() {
        for pic in tag.pictures() {
            let data = pic.data();
            if !data.is_empty() {
                return Ok(data.to_vec());
            }
        }
    }
    Err("未找到封面".into())
}
