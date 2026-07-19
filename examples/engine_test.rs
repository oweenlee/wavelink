//! 引擎功能自测：播放文件 + 键盘控制 seek/pause/resume/stop
//! 用法: cargo run --example engine_test -- <文件路径>
use std::io::BufRead;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use audio_core::{EngineEvent, EngineHandle};

fn main() {
    tracing_subscriber::fmt().with_env_filter("audio_core=info").init();
    let path = std::env::args().nth(1).expect("用法: engine_test <文件路径>");
    let file = std::path::Path::new(&path);
    if !file.exists() {
        eprintln!("文件不存在: {path}");
        return;
    }

    let (engine, events) = EngineHandle::start();
    engine.play(path.clone());

    let (cmd_tx, cmd_rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        let stdin = std::io::BufReader::new(std::io::stdin());
        for line in stdin.lines() {
            if let Ok(l) = line {
                if cmd_tx.send(l).is_err() { break; }
            }
        }
    });

    println!("开始播放: {path}");
    println!("按键: p=暂停 r=恢复 s=停止 q=退出 数字=seek到秒数");
    let start = Instant::now();
    let mut got_track = false;

    loop {
        match events.try_recv() {
            Ok(EngineEvent::TrackChanged(p)) => {
                let t = start.elapsed().as_secs_f64();
                println!("\n[{t:.2}s] TrackChanged: {p}");
                got_track = !p.is_empty();
                if p.is_empty() { break; }
            }
            Ok(EngineEvent::PlaybackStopped) => {
                let t = start.elapsed().as_secs_f64();
                println!("\n[{t:.2}s] PlaybackStopped");
                break;
            }
            Ok(EngineEvent::Error(e)) => {
                println!("\n[{:.2}s] Error: {e}", start.elapsed().as_secs_f64());
                break;
            }
            Ok(EngineEvent::Position(pos)) => {
                if got_track {
                    print!("\r[{:.1}s] pos={pos:.1}s  ", start.elapsed().as_secs_f64());
                    use std::io::Write;
                    let _ = std::io::stdout().flush();
                }
            }
            Ok(EngineEvent::DurationSecs(dur)) => {
                println!("\n[{:.2}s] duration: {dur:.1}s", start.elapsed().as_secs_f64());
            }
            Ok(EngineEvent::QueueChanged(queue, current)) => {
                println!("\n[{:.2}s] queue: {} tracks, current: {}", start.elapsed().as_secs_f64(), queue.len(), current);
            }
            Ok(EngineEvent::Spectrum(_)) => {}
            Err(crossbeam_channel::TryRecvError::Empty) => {}
            Err(crossbeam_channel::TryRecvError::Disconnected) => break,
        }

        match cmd_rx.try_recv() {
            Ok(line) => {
                let line = line.trim().to_lowercase();
                match line.as_str() {
                    "p" => { engine.pause(); println!("⏸ 暂停"); }
                    "r" => { engine.resume(); println!("▶ 恢复"); }
                    "s" => { engine.stop(); println!("⏹ 停止"); break; }
                    "q" => { engine.stop(); break; }
                    "" => {}
                    _ => {
                        if let Ok(secs) = line.parse::<f64>() {
                            let t = start.elapsed().as_secs_f64();
                            println!("[{t:.2}s] seek → {secs:.1}s");
                            engine.seek(secs);
                        } else {
                            println!("未知: {line}");
                        }
                    }
                }
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break,
        }

        // 防止忙循环
        std::thread::sleep(Duration::from_millis(50));
    }

    engine.stop();
    println!("\n测试结束");
}
