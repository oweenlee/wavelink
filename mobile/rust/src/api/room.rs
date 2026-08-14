//! 房间校正 FFI：REW 测量曲线 → 线性相位 FIR 校正滤波器
//!
//! 离线计算链路，对应 audio-core `dsp::room_correction`：
//! REW 导出的频响文本 → 解析/平滑 → 生成校正 FIR → 导出 32-bit float WAV，
//! 再经 `engine_load_ir` 载入 DSP 卷积级（`ConvolutionEq`）。
//! IR 采样率与管线不一致时卷积器会自动离线重采样，统一按 44100 生成。

use audio_core::dsp::room_correction as rc;

/// 校正配置（FRB 兼容结构；target 取 "flat" / "harman_tilt"）
#[derive(Debug, Clone)]
pub struct CorrectionConfig {
    /// 目标曲线："flat"（平坦）/ "harman_tilt"（房间缓降，1kHz 以下 +1.3dB/oct）
    pub target: String,
    /// FIR 长度（tap 数，偶数，64~65536，越大低频分辨率越高）
    pub taps: u32,
    /// 最大削减（dB，限制对峰/正偏差的衰减幅度，防过削）
    pub max_cut_db: f32,
    /// null 补偿上限（dB，限制对负偏差的补偿幅度，防硬补无效）
    pub null_limit_db: f32,
    /// 校正频率范围下限（Hz）
    pub freq_min: f32,
    /// 校正频率范围上限（Hz）
    pub freq_max: f32,
    /// 心理声学频段权重（300Hz 以下全量，向高频平滑递减）
    pub psycho_weighting: bool,
    /// 曲线平滑分辨率（octave，典型 1/6）
    pub smoothing_octave: f32,
    /// IR 峰值归一化 headroom（dB，预留防削峰余量）
    pub headroom_db: f32,
}

/// 单点频响数据（Hz / dB），测量曲线预览用
#[derive(Debug, Clone)]
pub struct FreqPoint {
    /// 频率（Hz）
    pub freq: f32,
    /// 电平（dB）
    pub level_db: f32,
}

/// 房间校正生成结果
#[derive(Debug, Clone)]
pub struct RoomCorrectionResult {
    /// 生成的 IR 系数（单声道，目标采样率）
    pub ir: Vec<f32>,
    /// IR 采样率
    pub sample_rate: u32,
    /// 整体归一化应用的增益（dB；负值 = 整体衰减，UI 应提示补偿音量）
    pub applied_gain_db: f32,
    /// 有效测量点数
    pub points: usize,
    /// 解析出的测量曲线（UI 预览用）
    pub measured: Vec<FreqPoint>,
}

/// 默认校正配置（与 core 对齐）
pub fn default_correction_config() -> CorrectionConfig {
    CorrectionConfig {
        target: "flat".into(),
        taps: 8192,
        max_cut_db: 12.0,
        null_limit_db: 3.0,
        freq_min: 20.0,
        freq_max: 16000.0,
        psycho_weighting: true,
        smoothing_octave: 1.0 / 6.0,
        headroom_db: 3.0,
    }
}

impl CorrectionConfig {
    fn to_core(&self) -> Result<rc::CorrectionConfig, String> {
        let target = match self.target.as_str() {
            "flat" => rc::TargetCurve::Flat,
            "harman_tilt" => rc::TargetCurve::HarmanTilt,
            other => return Err(format!("未知目标曲线: {other}（flat / harman_tilt）")),
        };
        if !(64..=65536).contains(&self.taps) || self.taps % 2 != 0 {
            return Err(format!("taps 需为 64..=65536 的偶数，当前 {}", self.taps));
        }
        if !self.freq_min.is_finite() || !self.freq_max.is_finite() || self.freq_min <= 0.0 || self.freq_max <= self.freq_min {
            return Err(format!("无效频率范围: {}..{} Hz", self.freq_min, self.freq_max));
        }
        Ok(rc::CorrectionConfig {
            target,
            taps: self.taps as usize,
            max_cut_db: self.max_cut_db,
            null_limit_db: self.null_limit_db,
            freq_range: (self.freq_min, self.freq_max),
            psycho_weighting: self.psycho_weighting,
            smoothing_octave: if self.smoothing_octave > 0.0 { self.smoothing_octave } else { 1.0 / 6.0 },
            headroom_db: self.headroom_db,
        })
    }
}

/// 解析 REW 频响导出文本（不生成 IR，供校验/预览）。
/// 返回有效测量点（Hz/dB），解析失败返回错误字符串。
pub fn parse_rew_text(text: String) -> Result<Vec<FreqPoint>, String> {
    let pts = rc::parse_rew_txt(&text)?;
    Ok(pts
        .into_iter()
        .map(|p| FreqPoint { freq: p.freq, level_db: p.level_db })
        .collect())
}

/// 生成房间校正 IR：REW 测量文本 → 校正 FIR 系数。
///
/// `sample_rate` 建议传引擎输出采样率（默认 44100）；生成的 WAV 在加载时
/// 若与管线采样率不一致会被卷积器自动重采样。
pub fn generate_room_correction(
    rew_txt: String,
    config: CorrectionConfig,
    sample_rate: u32,
) -> Result<RoomCorrectionResult, String> {
    let cfg = config.to_core()?;
    // 预览用测量曲线：多解析一次文本，成本可忽略（纯文本遍历）
    let measured = rc::parse_rew_txt(&rew_txt)?;
    let report = rc::generate_correction(&rew_txt, &cfg, sample_rate)?;
    Ok(RoomCorrectionResult {
        ir: report.ir,
        sample_rate: report.sample_rate,
        applied_gain_db: report.applied_gain_db,
        points: report.points,
        measured: measured
            .into_iter()
            .map(|p| FreqPoint { freq: p.freq, level_db: p.level_db })
            .collect(),
    })
}

/// 保存 IR 为 32-bit float WAV（单声道），供 `engine_load_ir` 加载。
pub fn save_ir_wav(ir: Vec<f32>, sample_rate: u32, path: String) -> Result<(), String> {
    rc::export_ir_wav(&ir, sample_rate, &path)
}