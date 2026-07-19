use audio_core::dsp::{default_peq_bands, DspPipeline, PeqBand, PresetName};
use once_cell::sync::OnceCell;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Once};

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

// ── 全局 DSP 管线（用于实时播放路径）──────────────────────────
// run_decoder 在推样本前会先过这个管线；Dart 端的开关/预设直接改它。
// 不能用 DspHandle（RustAutoOpaque，绑定在 Dart 端、无法在解码线程安全访问）。

static DSP_GLOBAL: OnceCell<Arc<Mutex<DspPipeline>>> = OnceCell::new();
static DSP_GLOBAL_INIT: Once = Once::new();
static DSP_ENABLED: AtomicBool = AtomicBool::new(true);

/// 采样率（与解码/播放一致）
const DSP_SAMPLE_RATE: u32 = 44100;
const DSP_CHANNELS: usize = 2;

/// 初始化全局 DSP 管线（幂等）
pub(crate) fn dsp_global_init() {
    DSP_GLOBAL_INIT.call_once(|| {
        let bands = default_peq_bands();
        let pipeline = DspPipeline::new(
            DSP_SAMPLE_RATE,
            DSP_CHANNELS,
            &bands,
            false,
            1.0,
            32,
        );
        let _ = DSP_GLOBAL.set(Arc::new(Mutex::new(pipeline)));
    });
}

/// 实时处理一帧交错 PCM（在解码线程调用）
pub(crate) fn dsp_global_process(samples: &mut [f32]) {
    if !dsp_global_is_enabled() {
        return;
    }
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            p.process(samples);
        }
    }
}

/// 整条管线开关
pub fn dsp_global_set_enabled(enabled: bool) {
    DSP_ENABLED.store(enabled, Ordering::Release);
}

/// 是否启用 DSP（解码线程读取，决定是否处理）
pub(crate) fn dsp_global_is_enabled() -> bool {
    DSP_ENABLED.load(Ordering::Acquire)
}

pub fn dsp_global_set_eq_band(index: u8, freq: f32, gain_db: f32, q: f32) {
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            p.set_peq_band(index as usize, &PeqBand { freq, gain_db, q }, DSP_SAMPLE_RATE as f32);
        }
    }
}

pub fn dsp_global_apply_preset(preset: EqPreset) {
    let bands = audio_core::dsp::preset_bands(preset.into());
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            for (i, band) in bands.iter().enumerate() {
                p.set_peq_band(i, band, DSP_SAMPLE_RATE as f32);
            }
        }
    }
}

pub fn dsp_global_set_crossfeed(enabled: bool) {
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            p.set_crossfeed(enabled);
        }
    }
}

pub fn dsp_global_set_stereo_widener(enabled: bool, width: f32) {
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            p.set_stereo_widener(enabled, width);
        }
    }
}

pub fn dsp_global_set_volume(volume: f32) {
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            p.set_volume(volume);
        }
    }
}

pub fn dsp_global_reset() {
    let bands = default_peq_bands();
    if let Some(g) = DSP_GLOBAL.get() {
        if let Ok(mut p) = g.lock() {
            for (i, band) in bands.iter().enumerate() {
                p.set_peq_band(i, band, DSP_SAMPLE_RATE as f32);
            }
            p.set_volume(1.0);
            p.set_crossfeed(false);
            p.set_stereo_widener(false, 1.0);
        }
    }
}
