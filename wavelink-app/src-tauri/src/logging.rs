//! 结构化日志初始化

use std::fs::File;
use std::path::PathBuf;
use std::sync::Mutex;

use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

/// 初始化 tracing：控制台 + 文件
pub fn init() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,wavelink=debug,lofty=error"));

    let file = open_log_file();

    let stdout_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stdout)
        .with_target(false);

    match file {
        Some(f) => {
            let file_layer = tracing_subscriber::fmt::layer()
                .with_writer(Mutex::new(f))
                .with_target(true)
                .with_ansi(false);
            tracing_subscriber::registry()
                .with(env_filter)
                .with(stdout_layer)
                .with(file_layer)
                .init();
        }
        None => {
            tracing_subscriber::registry()
                .with(env_filter)
                .with(stdout_layer)
                .init();
        }
    }
}

fn open_log_file() -> Option<File> {
    let mut dir: PathBuf = dirs_data_dir()?;
    std::fs::create_dir_all(&dir).ok()?;
    dir.push("wavelink.log");
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&dir)
    {
        Ok(f) => {
            eprintln!("log file: {}", dir.display());
            Some(f)
        }
        Err(e) => {
            eprintln!("cannot open log file {dir:?}: {e}");
            None
        }
    }
}

#[cfg(target_os = "macos")]
fn dirs_data_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join("Library").join("Logs"))
}

#[cfg(not(target_os = "macos"))]
fn dirs_data_dir() -> Option<PathBuf> {
    std::env::var("APPDATA")
        .ok()
        .map(|p| PathBuf::from(p).join("wavelink"))
        .or_else(|| {
            std::env::var("HOME")
                .ok()
                .map(|h| PathBuf::from(h).join(".wavelink"))
        })
}
