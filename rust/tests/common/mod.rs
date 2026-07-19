//! 测试辅助：获取 test-media 目录下的文件路径

/// 返回 test-media 目录下指定文件的完整路径
/// 注意：文件必须存在，否则调用 `unwrap()` 的测试会 panic
pub fn test_media(name: &str) -> String {
    let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test-media");
    base.join(name).to_string_lossy().to_string()
}
