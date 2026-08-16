//! 房间校正命令：REW 测量曲线 → 校正 FIR → 应用到 DSP 卷积级
//!
//! 离线计算链路（对齐移动端 room.rs）：
//! REW 频响导出文本 → 解析/平滑 → 生成校正 FIR → 导出 32-bit float WAV 到
//! app data 目录 → `engine.load_ir` 载入卷积级 → 持久化路径到 settings.json，
//! 启动时由 `restore_room_correction` 恢复（文件丢失则清理脏路径）。

use std::collections::HashMap;
use std::path::Path;

use serde::Serialize;
use tauri::{AppHandle, Manager, State};

use sdk::dsp::room_correction as rc;
use sdk::TARGET_SAMPLE_RATE;

use crate::settings;
use crate::state::AppState;

/// 房间校正 IR 在 settings.json 中的持久化 key
const ROOM_IR_PATH_KEY: &str = "roomCorrectionIrPath";

/// 校正配置（FRB 兼容结构；target 取 "flat" / "harman_tilt"）
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct CorrectionConfigDto {
    /// 目标曲线："flat"（平坦）/ "harman_tilt"（房间缓降，1kHz 以下 +1.3dB/oct）
    pub target: String,
    /// FIR 长度（tap 数，偶数，64~65536）
    pub taps: u32,
    /// 最大削减（dB，限制对峰/正偏差的衰减幅度）
    pub max_cut_db: f32,
    /// null 补偿上限（dB，限制对负偏差的补偿幅度）
    pub null_limit_db: f32,
    /// 校正频率范围下限（Hz）
    pub freq_min: f32,
    /// 校正频率范围上限（Hz）
    pub freq_max: f32,
    /// 心理声学频段权重（300Hz 以下全量，向高频平滑递减）
    pub psycho_weighting: bool,
    /// 曲线平滑分辨率（octave，典型 1/6）
    pub smoothing_octave: f32,
    /// IR 峰值归一化 headroom（dB）
    pub headroom_db: f32,
}

impl Default for CorrectionConfigDto {
    fn default() -> Self {
        let d = rc::CorrectionConfig::default();
        CorrectionConfigDto {
            target: "flat".into(),
            taps: d.taps as u32,
            max_cut_db: d.max_cut_db,
            null_limit_db: d.null_limit_db,
            freq_min: d.freq_range.0,
            freq_max: d.freq_range.1,
            psycho_weighting: d.psycho_weighting,
            smoothing_octave: d.smoothing_octave,
            headroom_db: d.headroom_db,
        }
    }
}

impl CorrectionConfigDto {
    fn to_core(&self) -> Result<rc::CorrectionConfig, String> {
        let target = match self.target.as_str() {
            "flat" => rc::TargetCurve::Flat,
            "harman_tilt" => rc::TargetCurve::HarmanTilt,
            other => return Err(format!("未知目标曲线: {other}（flat / harman_tilt）")),
        };
        if !(64..=65536).contains(&self.taps) || self.taps % 2 != 0 {
            return Err(format!("taps 需为 64..=65536 的偶数，当前 {}", self.taps));
        }
        if !self.freq_min.is_finite()
            || !self.freq_max.is_finite()
            || self.freq_min <= 0.0
            || self.freq_max <= self.freq_min
        {
            return Err(format!(
                "无效频率范围: {}..{} Hz",
                self.freq_min, self.freq_max
            ));
        }
        Ok(rc::CorrectionConfig {
            target,
            taps: self.taps as usize,
            max_cut_db: self.max_cut_db,
            null_limit_db: self.null_limit_db,
            freq_range: (self.freq_min, self.freq_max),
            psycho_weighting: self.psycho_weighting,
            smoothing_octave: if self.smoothing_octave > 0.0 {
                self.smoothing_octave
            } else {
                1.0 / 6.0
            },
            headroom_db: self.headroom_db,
        })
    }
}

/// 单点频响数据（Hz / dB），测量曲线预览用
#[derive(Debug, Clone, Serialize)]
pub struct FreqPointDto {
    pub freq: f32,
    pub level_db: f32,
}

impl From<rc::FreqPoint> for FreqPointDto {
    fn from(p: rc::FreqPoint) -> Self {
        FreqPointDto {
            freq: p.freq,
            level_db: p.level_db,
        }
    }
}

/// 房间校正生成报告（不含 IR 系数本身，前端无需下载大数组）
#[derive(Debug, Clone, Serialize)]
pub struct RoomCorrectionReportDto {
    /// IR 采样率
    pub sample_rate: u32,
    /// 整体归一化应用的增益（dB；负值 = 整体衰减，UI 应提示补偿音量）
    pub applied_gain_db: f32,
    /// 有效测量点数
    pub points: usize,
    /// 生成的 IR 长度（tap 数）
    pub ir_len: usize,
    /// 解析出的测量曲线（UI 预览用）
    pub measured: Vec<FreqPointDto>,
}

/// 房间校正 IR 的固定文件名（存 app data 目录，与 library.db 同目录）
fn room_ir_path(app: &AppHandle) -> Result<String, String> {
    let data_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(data_dir
        .join("room_correction_ir.wav")
        .to_string_lossy()
        .to_string())
}

/// 读取现有设置并合并（避免覆盖其他字段）
fn load_merged_settings() -> HashMap<String, serde_json::Value> {
    settings::load_settings().unwrap_or_default()
}

/// 默认校正配置（与 core 对齐）
#[tauri::command]
pub fn default_correction_config() -> CorrectionConfigDto {
    CorrectionConfigDto::default()
}

/// 解析 REW 频响导出文本（不生成 IR，供校验/预览）。
#[tauri::command]
pub fn parse_rew_text(text: String) -> Result<Vec<FreqPointDto>, String> {
    rc::parse_rew_txt(&text).map(|pts| pts.into_iter().map(FreqPointDto::from).collect())
}

/// 生成并应用房间校正：REW 测量文本 → 校正 FIR → 存 WAV → 载入卷积级 → 持久化路径。
#[tauri::command]
pub async fn generate_room_correction(
    rew_txt: String,
    config: CorrectionConfigDto,
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<RoomCorrectionReportDto, String> {
    let ir_path = room_ir_path(&app)?;
    let ir_path_for_task = ir_path.clone();
    let (measured, report) = tauri::async_runtime::spawn_blocking(move || {
        let cfg = config.to_core()?;
        // 预览用测量曲线
        let measured = rc::parse_rew_txt(&rew_txt)?;
        // 与 DSP 管线采样率一致生成 IR（卷积器加载时不一致也会自动重采样）
        let report = rc::generate_correction(&rew_txt, &cfg, TARGET_SAMPLE_RATE)?;
        rc::export_ir_wav(&report.ir, report.sample_rate, &ir_path_for_task)?;
        Ok::<_, String>((
            measured
                .into_iter()
                .map(FreqPointDto::from)
                .collect::<Vec<_>>(),
            report,
        ))
    })
    .await
    .map_err(|e| format!("room correction task failed: {e}"))??;

    state.engine.load_ir(ir_path.clone());

    // 持久化路径（对齐移动端：重启后由 restore_room_correction 恢复）
    let mut saved = load_merged_settings();
    saved.insert(ROOM_IR_PATH_KEY.into(), serde_json::Value::String(ir_path));
    settings::save_settings(saved)?;

    Ok(RoomCorrectionReportDto {
        sample_rate: report.sample_rate,
        applied_gain_db: report.applied_gain_db,
        points: report.points,
        ir_len: report.ir.len(),
        measured,
    })
}

/// 清除房间校正：引擎卷积级恢复直通，删除 IR 文件，清除持久化。
#[tauri::command]
pub fn clear_room_correction(state: State<AppState>) -> Result<(), String> {
    state.engine.clear_ir();

    let mut saved = load_merged_settings();
    if let Some(serde_json::Value::String(path)) = saved.remove(ROOM_IR_PATH_KEY) {
        if Path::new(&path).exists() {
            std::fs::remove_file(&path).ok();
        }
    }
    settings::save_settings(saved)
}

/// 查询当前持久化的房间校正 IR 路径（None = 未启用，前端初始化状态用）
#[tauri::command]
pub fn get_room_correction_path() -> Option<String> {
    let saved = settings::load_settings().ok()?;
    saved
        .get(ROOM_IR_PATH_KEY)
        .and_then(|v| v.as_str().map(String::from))
}

/// 启动时恢复房间校正：读取持久化路径并载入卷积级。
/// 文件被外部删除（清缓存/重装）时加载会失败，清理脏路径避免每次启动反复尝试。
pub(crate) fn restore_room_correction(app: &AppHandle) {
    let Ok(saved) = settings::load_settings() else {
        return;
    };
    let path = match saved.get(ROOM_IR_PATH_KEY) {
        Some(serde_json::Value::String(p)) => p.clone(),
        _ => return,
    };

    if Path::new(&path).exists() {
        app.state::<AppState>().engine.load_ir(path.clone());
        tracing::info!("房间校正 IR 已恢复: {path}");
    } else {
        let mut clean = saved;
        clean.remove(ROOM_IR_PATH_KEY);
        let _ = settings::save_settings(clean);
        tracing::warn!("房间校正 IR 文件丢失，已清理持久化路径: {path}");
    }
}
