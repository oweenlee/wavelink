fn main() {
    tauri_build::build();

    // 链接 macOS MediaPlayer 框架（MPNowPlayingInfoCenter）
    #[cfg(target_os = "macos")]
    println!("cargo:rustc-link-lib=framework=MediaPlayer");
}
