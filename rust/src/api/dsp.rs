use audio_core::dsp::{default_peq_bands, DspPipeline, PeqBand, PresetName};

/// DSP 均衡器频段参数
pub struct EqBand {
    pub freq: f32,
    pub gain_db: f32,
    pub q: f32,
}

impl From<EqBand> for PeqBand {
    fn from(b: EqBand) -> Self {
        PeqBand {
            freq: b.freq,
            gain_db: b.gain_db,
            q: b.q,
        }
    }
}

/// 预设均衡器名称
pub enum EqPreset {
    Flat,
    Rock,
    Pop,
    Dance,
    Classical,
    Soft,
    FullBass,
    FullTreble,
    Techno,
    Vocals,
}

impl From<EqPreset> for PresetName {
    fn from(p: EqPreset) -> Self {
        match p {
            EqPreset::Flat => PresetName::Flat,
            EqPreset::Rock => PresetName::Rock,
            EqPreset::Pop => PresetName::Pop,
            EqPreset::Dance => PresetName::Dance,
            EqPreset::Classical => PresetName::Classical,
            EqPreset::Soft => PresetName::Soft,
            EqPreset::FullBass => PresetName::FullBass,
            EqPreset::FullTreble => PresetName::FullTreble,
            EqPreset::Techno => PresetName::Techno,
            EqPreset::Vocals => PresetName::Vocals,
        }
    }
}

/// DSP 管线句柄
pub struct DspHandle {
    inner: DspPipeline,
    sample_rate: u32,
}

/// 创建 DSP 管线
pub fn create_dsp(
    sample_rate: u32,
    channels: u8,
    volume: f32,
    bits: u8,
) -> DspHandle {
    let bands = default_peq_bands();
    let inner = DspPipeline::new(
        sample_rate,
        channels as usize,
        &bands,
        false,
        volume,
        bits as u32,
    );
    DspHandle { inner, sample_rate }
}

/// 设置均衡器频段
pub fn dsp_set_eq_band(handle: &mut DspHandle, index: u8, band: EqBand) {
    handle
        .inner
        .set_peq_band(index as usize, &band.into(), handle.sample_rate as f32);
}

/// 应用均衡器预设
pub fn dsp_apply_preset(handle: &mut DspHandle, preset: EqPreset) {
    let bands = audio_core::dsp::preset_bands(preset.into());
    for (i, band) in bands.iter().enumerate() {
        handle
            .inner
            .set_peq_band(i, band, handle.sample_rate as f32);
    }
}

/// 设置音量 (0.0~1.5)
pub fn dsp_set_volume(handle: &mut DspHandle, volume: f32) {
    handle.inner.set_volume(volume);
}

/// 启用/关闭串音补偿
pub fn dsp_set_crossfeed(handle: &mut DspHandle, enabled: bool) {
    handle.inner.set_crossfeed(enabled);
}

/// 启用/关闭立体声展宽
pub fn dsp_set_stereo_widener(handle: &mut DspHandle, enabled: bool, width: f32) {
    handle.inner.set_stereo_widener(enabled, width);
}

/// 处理 PCM 音频数据（f32 交错样本，原地处理并返回）
pub fn dsp_process(handle: &mut DspHandle, samples: Vec<f32>) -> Vec<f32> {
    let mut buf = samples;
    handle.inner.process(&mut buf);
    buf
}

/// 重置 DSP 到默认状态
pub fn dsp_reset(handle: &mut DspHandle) {
    let bands = default_peq_bands();
    for (i, band) in bands.iter().enumerate() {
        handle
            .inner
            .set_peq_band(i, band, handle.sample_rate as f32);
    }
    handle.inner.set_volume(1.0);
    handle.inner.set_crossfeed(false);
    handle.inner.set_stereo_widener(false, 1.0);
}
