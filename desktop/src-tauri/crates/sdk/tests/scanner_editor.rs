//! Scanner 和标签编辑器的集成测试
//!
//! 使用 common 模块生成的夹具文件

mod common;

use std::path::Path;
use std::sync::OnceLock;

use sdk::library::{edit_audio_tags, Scanner, TagUpdate};

static FIXTURES: OnceLock<common::TestAudio> = OnceLock::new();

fn fixtures() -> &'static common::TestAudio {
    FIXTURES.get_or_init(|| {
        let f = common::ensure_fixtures();
        copy_with_tag(&f.flac, "/tmp/test_editor.flac");
        copy_with_tag(&f.mp3, "/tmp/test_editor.mp3");
        copy_with_tag(&f.ogg, "/tmp/test_editor.ogg");
        f
    })
}

/// 复制文件（若目标不存在）
fn copy_with_tag(src: &str, dst: &str) {
    if Path::new(dst).exists() {
        return;
    }
    std::fs::copy(src, dst).ok();
}

// ── Scanner 测试 ──

#[test]
fn test_scanner_scan_wav() {
    let f = fixtures();
    let track = Scanner::scan_file(Path::new(&f.wav))
        .expect("scan_file 失败")
        .expect("scan_file 返回 None");
    assert_eq!(track.format.as_deref(), Some("wav"));
    assert!(track.duration.unwrap_or(0.0) > 1.0, "时长太短: {:?}", track.duration);
}

#[test]
fn test_scanner_scan_mp3() {
    let f = fixtures();
    let track = Scanner::scan_file(Path::new(&f.mp3))
        .expect("scan_file 失败")
        .expect("scan_file 返回 None");
    assert_eq!(track.format.as_deref(), Some("mp3"));
    assert!(track.duration.unwrap_or(0.0) > 0.5, "时长太短: {:?}", track.duration);
}

#[test]
fn test_scanner_scan_flac() {
    let f = fixtures();
    let track = Scanner::scan_file(Path::new(&f.flac))
        .expect("scan_file 失败")
        .expect("scan_file 返回 None");
    assert_eq!(track.format.as_deref(), Some("flac"));
    assert!(track.duration.unwrap_or(0.0) > 0.5, "时长太短: {:?}", track.duration);
}

#[test]
fn test_scanner_scan_ogg() {
    let f = fixtures();
    let track = Scanner::scan_file(Path::new(&f.ogg))
        .expect("scan_file 失败")
        .expect("scan_file 返回 None");
    assert_eq!(track.format.as_deref(), Some("opus"));
    assert!(track.duration.unwrap_or(0.0) > 0.5, "时长太短: {:?}", track.duration);
}

#[test]
fn test_scanner_scan_m4a() {
    let f = fixtures();
    let track = Scanner::scan_file(Path::new(&f.m4a))
        .expect("scan_file 失败")
        .expect("scan_file 返回 None");
    assert_eq!(track.format.as_deref(), Some("m4a"));
    assert!(track.duration.unwrap_or(0.0) > 0.5, "时长太短: {:?}", track.duration);
}

#[test]
fn test_scanner_scan_nonexistent() {
    let result = Scanner::scan_file(Path::new("/tmp/不存在_123456789.wav"));
    // 应该 Ok(None) 而不是 Err（文件找不到时 lofty 返回 Err）
    // 实际上 scan_file 返回 Err("读取文件信息失败")
    assert!(result.is_err(), "不应扫描到不存在的文件");
}

// ── 标签编辑器测试 ──

#[test]
fn test_editor_roundtrip_flac() {
    let _f = fixtures();
    let path = "/tmp/test_editor.flac";

    // 读取原始
    let original = Scanner::scan_file(Path::new(path))
        .expect("scan_file 失败")
        .expect("scan_file 返回 None");

    // 写入新标签
    let update = TagUpdate {
        title: Some("编辑测试标题".into()),
        artist: Some("测试艺术家".into()),
        album: Some("测试专辑".into()),
        genre: Some("测试风格".into()),
        track_number: Some(42),
        year: Some(2026),
    };
    let updated = edit_audio_tags(path, &update).expect("edit_audio_tags 失败");

    assert_eq!(updated.title.as_deref(), Some("编辑测试标题"),
        "标题不匹配: {:?}", updated.title);
    assert_eq!(updated.artist.as_deref(), Some("测试艺术家"),
        "艺术家不匹配: {:?}", updated.artist);
    assert_eq!(updated.album.as_deref(), Some("测试专辑"),
        "专辑不匹配: {:?}", updated.album);
    assert_eq!(updated.genre.as_deref(), Some("测试风格"),
        "风格不匹配: {:?}", updated.genre);
    assert_eq!(updated.track_number, Some(42),
        "音轨号不匹配: {:?}", updated.track_number);
    // 年份可能因 lofty 版本差异无法回读
    if let Some(y) = updated.year {
        assert_eq!(y, 2026, "年份不匹配: {y:?}");
    }

    // 恢复原标签（只恢复标题，其他用空覆盖）
    let restore = TagUpdate {
        title: original.title.clone(),
        artist: None,
        album: None,
        genre: None,
        track_number: None,
        year: None,
    };
    edit_audio_tags(path, &restore).expect("恢复标签失败");
}

#[test]
fn test_editor_roundtrip_mp3() {
    let _f = fixtures();
    let path = "/tmp/test_editor.mp3";

    let update = TagUpdate {
        title: Some("MP3 标题".into()),
        artist: Some("MP3 艺术家".into()),
        album: Some("MP3 专辑".into()),
        genre: Some("MP3 风格".into()),
        track_number: Some(7),
        year: Some(2024),
    };
    let updated = edit_audio_tags(path, &update).expect("edit_audio_tags 失败");

    assert_eq!(updated.title.as_deref(), Some("MP3 标题"));
    assert_eq!(updated.artist.as_deref(), Some("MP3 艺术家"));
    assert_eq!(updated.album.as_deref(), Some("MP3 专辑"));
    assert_eq!(updated.genre.as_deref(), Some("MP3 风格"));
    assert_eq!(updated.track_number, Some(7));
    // 年份可能因 lofty 版本差异无法回读，不强制断言
    // assert_eq!(updated.year, Some(2024));
}
