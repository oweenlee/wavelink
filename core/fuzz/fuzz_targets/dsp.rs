#![no_main]

/// DSP 管线模糊测试
/// 用随机音频帧喂给 DSP 管线，检测崩溃/异常输出
use libfuzzer_sys::fuzz_target;
use audio_core::dsp::{DspPipeline, default_peq_bands};

fuzz_target!(|data: &[u8]| {
    if data.len() < 8 || data.len() > 256 * 1024 {
        return;
    }

    // 将随机字节转为 f32 音频样本（可能包含 NaN/Inf）
    let mut samples: Vec<f32> = data
        .chunks(4)
        .map(|c| {
            if c.len() < 4 {
                0.0
            } else {
                f32::from_le_bytes([c[0], c[1], c[2], c[3]])
            }
        })
        .collect();

    // 补齐到 2 的倍数（立体声）
    if samples.len() % 2 != 0 {
        samples.push(0.0);
    }
    if samples.len() < 64 {
        return;
    }

    // 用默认 PEQ + 常规设置测试
    let bands = default_peq_bands();
    let mut dsp = DspPipeline::new(44100, 2, &bands, true, 0.8, 16);
    let _ = dsp.process(&mut samples);

    // 不带 crossfeed
    let mut dsp2 = DspPipeline::new(44100, 2, &bands, false, 1.0, 24);
    let _ = dsp2.process(&mut samples);

    // 单声道
    let bands_mono = default_peq_bands();
    let mut dsp3 = DspPipeline::new(44100, 1, &bands_mono, false, 0.5, 16);
    let _ = dsp3.process(&mut samples);
});
