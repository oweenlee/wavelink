//! 诊断：验证 lofty 内存探针对真实音频文件头部的封面解析能力。
//! 运行：cargo test --test cover_probe_diag -- --ignored --nocapture

use std::fs;

fn probe(name: &str, data: &[u8]) {
    use lofty::file::TaggedFileExt;
    let mut reader = std::io::Cursor::new(data);
    let probed: Result<lofty::file::TaggedFile, lofty::error::LoftyError> =
        match lofty::probe::Probe::new(&mut reader).guess_file_type() {
            Ok(p) => p.read(),
            Err(e) => Err(e.into()),
        };
    match probed {
        Ok(tagged) => {
            let mut cover = None;
            'outer: for tag in tagged.tags() {
                for pic in tag.pictures() {
                    cover = Some(pic.data().len());
                    break 'outer;
                }
            }
            let has_pic = match cover {
                Some(n) => format!("cover={n}B"),
                None => "no-picture".into(),
            };
            eprintln!("[diag] {name}: OK {has_pic}");
        }
        Err(e) => eprintln!("[diag] {name}: FAIL {e}"),
    }
}

#[test]
#[ignore = "诊断用：cargo test --test cover_probe_diag -- --ignored --nocapture"]
fn probe_local_music_heads() {
    let dir = "/Users/qin/Public/music";
    let Ok(entries) = fs::read_dir(dir) else {
        eprintln!("[diag] 目录不存在");
        return;
    };
    let mut count = 0usize;
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
            continue;
        };
        if !matches!(
            ext.to_lowercase().as_str(),
            "mp3" | "flac" | "ogg" | "m4a" | "wav" | "ape" | "wv" | "aif" | "aiff"
        ) {
            continue;
        }
        let Ok(data) = fs::read(&path) else { continue };
        // 截取前 4MB（与 NAS 封面的 smbReadHead 一致）
        let head = &data[..data.len().min(4 * 1024 * 1024)];
        probe(&path.display().to_string(), head);
        count += 1;
        if count >= 30 {
            break;
        }
    }
}