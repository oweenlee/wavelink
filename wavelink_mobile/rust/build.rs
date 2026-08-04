//! 构建脚本：仅在 macOS 宿主构建（含 `cargo test`）时链接 CoreAudio 系框架。
//!
//! audio-core 的 `output_coreaudio` / `exclusive` 模块（`#[cfg(target_os = "macos")]`）
//! 引用了 CoreAudio 符号。iOS 真机构建 target_os = "ios"，不编译这些模块，
//! 框架由 Xcode 链接，故此处分支不会触发、不影响 iOS。
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        for f in ["CoreAudio", "AudioToolbox", "CoreFoundation", "CoreServices"] {
            println!("cargo:rustc-link-lib=framework={f}");
        }
    }
}
