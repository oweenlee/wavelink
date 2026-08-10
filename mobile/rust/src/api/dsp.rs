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

/// AutoEQ 耳机校正档案目录（oratory1990 实测，型号名供设置页展示，
/// 选中后经 `engine_set_auto_eq` 应用）
pub fn auto_eq_catalog() -> Vec<String> {
    audio_core::dsp::autoeq::catalog()
        .iter()
        .map(|p| p.name.to_string())
        .collect()
}
