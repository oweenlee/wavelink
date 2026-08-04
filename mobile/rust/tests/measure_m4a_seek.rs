//! 测量 m4a 单次 seek 的真实耗时（从 start(seek) 到首帧产出）
use std::time::{Duration, Instant};
use rust_lib_wavelink_mobile::decode::decode_file;

#[test]
#[ignore = "手动诊断工具：硬编码本地文件路径，默认跳过；cargo test -- --ignored 可手动运行"]
fn measure_m4a_seek_latency() {
    let path = "/Users/qin/Desktop/demos/a_music/李荣浩-恋人.m4a";
    if !std::path::Path::new(path).exists() { eprintln!("缺失"); return; }
    // 用 stream_decoder 接口测 seek 延迟
    for i in 0..5 {
        let target = 10.0 + i as f64 * 40.0;
        let t0 = Instant::now();
        let mut dec = rust_lib_wavelink_mobile::decode::stream_decoder_create(path.to_string(), Some(target)).unwrap();
        // 等首块
        let first = loop {
            match rust_lib_wavelink_mobile::decode::stream_decoder_next_chunk(&mut dec) {
                Ok(Some(c)) => break Some(c.samples.len()),
                Ok(None) => break None,
                Err(e) => { eprintln!("err {e}"); break None; }
            }
        };
        let dt = t0.elapsed();
        eprintln!("seek->{:.0}s 耗时 {:.1}ms, 首块样本 {}", target, dt.as_secs_f64()*1000.0, first.unwrap_or(0));
        rust_lib_wavelink_mobile::decode::stream_decoder_stop(&mut dec);
        std::thread::sleep(Duration::from_millis(50));
    }
    // 对照：无 seek 启动耗时
    let t0 = Instant::now();
    let mut dec = rust_lib_wavelink_mobile::decode::stream_decoder_create(path.to_string(), None).unwrap();
    let _ = rust_lib_wavelink_mobile::decode::stream_decoder_next_chunk(&mut dec);
    eprintln!("无seek启动耗时 {:.1}ms", t0.elapsed().as_secs_f64()*1000.0);
    rust_lib_wavelink_mobile::decode::stream_decoder_stop(&mut dec);
    let _ = decode_file(path.to_string()); // 确保编译引用
}
