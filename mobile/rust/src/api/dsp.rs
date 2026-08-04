//! DSP 预设枚举（FRB 兼容层）
//!
//! 实际 DSP 控制已迁移至 EngineHandle（见 engine.rs）。
//! 此枚举保留仅用于 FRB 代码生成兼容。

use audio_core::dsp::PresetName;

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
