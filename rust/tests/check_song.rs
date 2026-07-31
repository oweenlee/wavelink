//! 检查单个音频文件的解码质量 + 快速 seek 鲁棒性
use rust_lib_wavelink_mobile::decode::decode_file;

#[test]
#[ignore = "手动诊断工具：硬编码本地文件路径，默认跳过；cargo test -- --ignored 可手动运行"]
fn check_lironghao_lianren() {
    let path = "/Users/qin/Desktop/demos/a_music/李荣浩-恋人.m4a";
    let r = match decode_file(path.to_string()) {
        Ok(r) => r,
        Err(e) => { eprintln!("解码失败: {e}"); return; }
    };
    let pcm = &r.samples;
    let frames = pcm.len() / 2;
    eprintln!("采样率 {} 声道 {} 帧数 {} 时长 {:.2}s", r.sample_rate, r.channels, frames, frames as f64 / r.sample_rate as f64);

    // 统计静音/低能量、NaN/Inf、峰值
    let mut nan = 0usize;
    let mut peak = 0.0f32;
    let mut silent_frames = 0usize;
    let mut nonzero_start = frames;
    let mut nonzero_end = 0usize;
    for f in 0..frames {
        let l = pcm[f*2];
        let rr = pcm[f*2+1];
        if !l.is_finite() || !rr.is_finite() { nan += 1; }
        let m = l.abs().max(rr.abs());
        if m > peak { peak = m; }
        if m < 1e-3 { silent_frames += 1; } else {
            if f < nonzero_start { nonzero_start = f; }
            if f > nonzero_end { nonzero_end = f; }
        }
    }
    eprintln!("NaN/Inf 样本: {nan}");
    eprintln!("峰值: {:.4}", peak);
    eprintln!("静音帧: {silent_frames} / {frames} ({:.1}%)", silent_frames as f64/frames as f64*100.0);
    eprintln!("首个非静音帧: {:.2}s, 末个非静音帧: {:.2}s", nonzero_start as f64/r.sample_rate as f64, nonzero_end as f64/r.sample_rate as f64);

    // 连续零跳变检测：相邻帧样本差过大（爆音/clip）
    let mut big_jump = 0usize;
    for f in 1..frames {
        let d = (pcm[f*2] - pcm[(f-1)*2]).abs().max((pcm[f*2+1]-pcm[(f-1)*2+1]).abs());
        if d > 0.5 { big_jump += 1; }
    }
    eprintln!("相邻帧大跳变(>0.5)次数: {big_jump}");
}
