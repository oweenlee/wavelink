//! AutoEQ 耳机校正（基于 AutoEq 社区测量数据）
//!
//! 为常见耳机/耳塞提供参数化 EQ 校正档案，目标曲线为 oratory1990
//! （基于 Harman 目标）。数据来源：github.com/jaakkopasanen/AutoEq (MIT)，
//! 内嵌于 [`autoeq_data`](autoeq_data.rs)，离线可用。
//!
//! 用法：
//! ```no_run
//! use audio_core::dsp::autoeq;
//! // 列出所有可用耳机
//! let names: Vec<&str> = autoeq::catalog().iter().map(|p| p.name).collect();
//! // 查找档案并转为 PEQ 频段
//! if let Some(profile) = autoeq::find_profile("Sennheiser HD 600") {
//!     let bands = autoeq::profile_to_peq_bands(profile);
//!     for (i, band) in bands.iter().enumerate() {
//!         // engine.set_peq_band(i, band.clone());
//!     }
//!     // profile.preamp_db 为建议前置增益（防止正增益削峰），
//!     // 可通过 engine.set_replaygain_gain() 或音量补偿应用
//! }
//! ```

mod autoeq_data;

/// 档案滤波器类型（与 PEQ 的 [`PeqKind`](super::pipeline::PeqKind) 对应）
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProfileFilterKind {
    /// 峰值滤波器
    Peaking,
    /// 低频搁架
    LowShelf,
    /// 高频搁架
    HighShelf,
}

/// 档案中的单个滤波器
#[derive(Debug, Clone, Copy)]
pub struct ProfileFilter {
    /// 滤波器类型
    pub kind: ProfileFilterKind,
    /// 频率 Hz（shelf 为拐点频率）
    pub freq: f32,
    /// 增益 dB
    pub gain_db: f32,
    /// Q 值
    pub q: f32,
}

/// 耳机佩戴形式
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum HeadphoneForm {
    /// 头戴式
    OverEar,
    /// 入耳式
    InEar,
}

/// 耳机校正档案
#[derive(Debug, Clone, Copy)]
pub struct HeadphoneProfile {
    /// 耳机型号名（与 AutoEq 数据库一致）
    pub name: &'static str,
    /// 佩戴形式
    pub form: HeadphoneForm,
    /// 建议前置增益 dB（通常为负，用于给正增益滤波器留余量防削峰）
    pub preamp_db: f32,
    /// 参数化滤波器列表（按 AutoEq 输出顺序）
    pub filters: &'static [ProfileFilter],
}

/// 返回全部内嵌档案
pub fn catalog() -> &'static [HeadphoneProfile] {
    autoeq_data::PROFILES
}

/// 按型号名查找档案（大小写不敏感）
pub fn find_profile(name: &str) -> Option<&'static HeadphoneProfile> {
    autoeq_data::PROFILES
        .iter()
        .find(|p| p.name.eq_ignore_ascii_case(name))
}

/// 模糊搜索档案（型号名包含关键字，大小写不敏感）
pub fn search_profiles(keyword: &str) -> Vec<&'static HeadphoneProfile> {
    let kw = keyword.to_ascii_lowercase();
    autoeq_data::PROFILES
        .iter()
        .filter(|p| p.name.to_ascii_lowercase().contains(&kw))
        .collect()
}

/// 将档案转换为 PEQ 频段（可直接喂给 `EngineHandle::set_peq_band`）
pub fn profile_to_peq_bands(profile: &HeadphoneProfile) -> Vec<super::pipeline::PeqBand> {
    use super::pipeline::{PeqBand, PeqKind};
    profile
        .filters
        .iter()
        .map(|f| PeqBand {
            freq: f.freq,
            gain_db: f.gain_db,
            q: f.q,
            kind: match f.kind {
                ProfileFilterKind::Peaking => PeqKind::Peaking,
                ProfileFilterKind::LowShelf => PeqKind::LowShelf,
                ProfileFilterKind::HighShelf => PeqKind::HighShelf,
            },
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_not_empty() {
        assert!(catalog().len() >= 30, "应内嵌至少 30 个档案");
    }

    #[test]
    fn find_profile_case_insensitive() {
        assert!(find_profile("Sennheiser HD 600").is_some());
        assert!(find_profile("sennheiser hd 600").is_some());
        assert!(find_profile("不存在型号 XYZ").is_none());
    }

    #[test]
    fn search_by_keyword() {
        let results = search_profiles("HD 6");
        assert!(results.iter().any(|p| p.name == "Sennheiser HD 600"));
        assert!(results.iter().any(|p| p.name == "Sennheiser HD 650"));
    }

    #[test]
    fn profiles_have_valid_filters() {
        for p in catalog() {
            assert!(!p.filters.is_empty(), "{} 应有滤波器", p.name);
            assert!(p.filters.len() <= 31, "{} 滤波器数超出 PEQ 槽位", p.name);
            for f in p.filters {
                assert!(
                    f.freq > 0.0 && f.freq <= 22000.0,
                    "{} 频率异常: {}",
                    p.name,
                    f.freq
                );
                assert!(
                    f.gain_db.abs() <= 20.0,
                    "{} 增益异常: {}",
                    p.name,
                    f.gain_db
                );
                assert!(f.q > 0.0 && f.q <= 20.0, "{} Q 异常: {}", p.name, f.q);
            }
        }
    }

    #[test]
    fn profile_to_peq_bands_maps_kind() {
        use super::super::pipeline::PeqKind;
        let p = find_profile("Sennheiser HD 600").unwrap();
        let bands = profile_to_peq_bands(p);
        assert_eq!(bands.len(), p.filters.len());
        // HD 600 第一个滤波器是 105Hz 低频搁架（经典低音补偿）
        assert_eq!(bands[0].kind, PeqKind::LowShelf);
        assert!((bands[0].freq - 105.0).abs() < 0.01);
        assert!(bands[0].gain_db > 4.0, "HD600 应有显著低音补偿");
    }

    #[test]
    fn preamp_is_negative_or_zero() {
        // AutoEq 的 preamp 用于防削峰，几乎总是负值
        for p in catalog() {
            assert!(
                p.preamp_db <= 0.5,
                "{} preamp 异常: {}",
                p.name,
                p.preamp_db
            );
        }
    }
}
