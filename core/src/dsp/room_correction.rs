//! 房间校正：REW 测量曲线 → 线性相位 FIR 校正滤波器
//!
//! 离线计算模块，不触碰实时路径，不新增依赖（复用 `realfft`）。
//! 生成的 IR 系数导出为 32-bit float WAV 后，走现有
//! [`crate::dsp::convolver::ConvolutionEq`] 卷积级加载，无需改动 DSP 执行链路。
//!
//! 校正原则（防削峰/防烧单元）：
//! - 只校正测量点到目标曲线的偏差：峰（正偏差）衰减，null（负偏差）提升
//! - 峰衰减受 `max_cut_db` 限幅；null 提升受 `null_limit_db` 限幅——
//!   null 多为空间性抵消，硬补无效且危险
//! - `freq_range` 之外不做校正（低频以下测量不可靠，高频以上空间平均失效）
//! - 心理声学权重：300Hz 以下全量校正（房间模式主导），向高频平滑递减
//! - 整体增益按 `headroom_db` 归一化，报告 `applied_gain_db` 供 UI 提示

use realfft::{num_complex::Complex32, RealFftPlanner};

/// 校正目标曲线
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum TargetCurve {
    /// 平坦目标（0 dB）
    Flat,
    /// 房间缓降：1kHz 以下按 -1.3dB/oct 缓升（补偿听感的房间增益），1kHz 以上平坦
    HarmanTilt,
}

/// 校正配置
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CorrectionConfig {
    /// 目标曲线
    pub target: TargetCurve,
    /// FIR 长度（tap 数，建议 4096~32768，越大低频分辨率越高）
    pub taps: usize,
    /// 最大削减（dB，限制对峰/正偏差的衰减幅度）
    pub max_cut_db: f32,
    /// null 补偿上限（dB，限制对负偏差的补偿幅度）
    pub null_limit_db: f32,
    /// 校正频率范围 (Hz)，范围外增益为 0dB
    pub freq_range: (f32, f32),
    /// 心理声学频段权重（300Hz 以下全量，向高频递减）
    pub psycho_weighting: bool,
    /// 曲线平滑分辨率（octave，典型 1/6）
    pub smoothing_octave: f32,
    /// IR 峰值归一化 headroom（dB，预留防削峰余量）
    pub headroom_db: f32,
}

impl Default for CorrectionConfig {
    fn default() -> Self {
        CorrectionConfig {
            target: TargetCurve::Flat,
            taps: 8192,
            max_cut_db: 12.0,
            null_limit_db: 3.0,
            freq_range: (20.0, 16000.0),
            psycho_weighting: true,
            smoothing_octave: 1.0 / 6.0,
            headroom_db: 3.0,
        }
    }
}

/// 校正结果报告
#[derive(Debug, Clone)]
pub struct CorrectionReport {
    /// 生成的 IR 系数（单声道，目标采样率）
    pub ir: Vec<f32>,
    /// IR 采样率
    pub sample_rate: u32,
    /// 整体归一化应用的增益（dB，负值 = 整体衰减，UI 应提示用户补偿音量）
    pub applied_gain_db: f32,
    /// 有效测量点数
    pub points: usize,
}

/// 单点频响数据（Hz / dB）
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FreqPoint {
    /// 频率（Hz）
    pub freq: f32,
    /// 电平（dB）
    pub level_db: f32,
}

/// 解析 REW 频响导出文本。
///
/// 格式：`*` 开头为注释行，首个含 "freq"（大小写不敏感）的行是表头，
/// 数据行取前两列（freq, level），逗号或 Tab 分隔。
/// 自动过滤非法行（freq ≤ 0 / 非有限值 / 列数不足），按频率排序去重。
pub fn parse_rew_txt(text: &str) -> Result<Vec<FreqPoint>, String> {
    let mut points = Vec::new();
    let mut seen_header = false;
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('*') {
            continue;
        }
        if !seen_header && t.to_ascii_lowercase().contains("freq") {
            seen_header = true;
            continue;
        }
        // 无表头格式：直接尝试按数据行解析
        let fields: Vec<&str> = if t.contains('\t') {
            t.split('\t').collect()
        } else {
            t.split(',').collect()
        };
        if fields.len() < 2 {
            continue;
        }
        let freq: f32 = match fields[0].trim().parse::<f32>() {
            Ok(f) if f > 0.0 && f.is_finite() => f,
            _ => continue,
        };
        let level: f32 = match fields[1].trim().parse::<f32>() {
            Ok(v) if v.is_finite() => v,
            _ => continue,
        };
        points.push(FreqPoint { freq, level_db: level });
    }
    if points.len() < 2 {
        return Err("REW 数据点不足（至少 2 个有效点）".into());
    }
    points.sort_by(|a, b| a.freq.partial_cmp(&b.freq).unwrap_or(std::cmp::Ordering::Equal));
    points.dedup_by(|a, b| a.freq == b.freq);
    if points.len() < 2 {
        return Err("REW 去重后数据点不足".into());
    }
    Ok(points)
}

/// log-线性插值到对数等间距频率栅格
fn interpolate_log(points: &[FreqPoint], freqs: &[f32]) -> Vec<f32> {
    let first = points[0];
    let last = points[points.len() - 1];
    let mut idx = 0usize;
    freqs
        .iter()
        .map(|&f| {
            if f <= first.freq {
                return first.level_db;
            }
            if f >= last.freq {
                return last.level_db;
            }
            while idx + 1 < points.len() && points[idx + 1].freq < f {
                idx += 1;
            }
            let a = points[idx];
            let b = points[idx + 1];
            let t = (f / a.freq).ln() / (b.freq / a.freq).ln();
            a.level_db + t * (b.level_db - a.level_db)
        })
        .collect()
}

/// 对数域滑动平均平滑（窗口半径 = span_octave 个倍频程）
fn smooth_octave(db: &mut [f32], freqs: &[f32], span_octave: f32) {
    if span_octave <= 0.0 || freqs.len() < 3 {
        return;
    }
    let n = freqs.len();
    let input = db.to_vec();
    for i in 0..n {
        let f_lo = freqs[i] / 2f32.powf(span_octave);
        let f_hi = freqs[i] * 2f32.powf(span_octave);
        let mut sum = 0.0f32;
        let mut count = 0usize;
        for j in 0..n {
            if freqs[j] >= f_lo && freqs[j] <= f_hi {
                sum += input[j];
                count += 1;
            }
        }
        if count > 0 {
            db[i] = sum / count as f32;
        }
    }
}

/// 心理声学权重：300Hz 以下 1.0，2kHz 以上 0.3，中间 smoothstep 过渡
fn psycho_weight(freq: f32) -> f32 {
    if freq <= 300.0 {
        return 1.0;
    }
    if freq >= 2000.0 {
        return 0.3;
    }
    let t = ((freq / 300.0).ln() / (2000.0f32 / 300.0).ln()).clamp(0.0, 1.0);
    let s = t * t * (3.0 - 2.0 * t);
    1.0 - 0.7 * s
}

/// 目标曲线响应（dB）
fn target_db(freq: f32, target: TargetCurve) -> f32 {
    match target {
        TargetCurve::Flat => 0.0,
        TargetCurve::HarmanTilt => {
            if freq < 1000.0 {
                1.3 * (1000.0 / freq).log2()
            } else {
                0.0
            }
        }
    }
}

/// 计算校正曲线（dB）：对偏差取负（峰→衰减，null→提升）→ 双向限幅 → 频段权重 → 范围外置零
fn correction_curve(freqs: &[f32], measured: &[f32], cfg: &CorrectionConfig) -> Vec<f32> {
    freqs
        .iter()
        .zip(measured.iter())
        .map(|(&f, &m)| {
            if f < cfg.freq_range.0 || f > cfg.freq_range.1 {
                return 0.0;
            }
            let dev = m - target_db(f, cfg.target);
            // 峰（dev>0）→ 衰减，限幅 max_cut_db；null（dev<0）→ 提升，限幅 null_limit_db
            let limited = (-dev).clamp(-cfg.max_cut_db, cfg.null_limit_db);
            if cfg.psycho_weighting {
                limited * psycho_weight(f)
            } else {
                limited
            }
        })
        .collect()
}

/// 频域采样法设计线性相位 FIR：校正曲线（dB 栅格）→ IR 系数。
///
/// 频谱加 (N-1)/2 样本的线性相位项，IFFT 后冲激响应居中于 N/2，
/// 再施加 Hann 窗控制截断旁瓣。
fn design_fir(freqs: &[f32], corr_db: &[f32], taps: usize, sample_rate: u32) -> Result<Vec<f32>, String> {
    if !(64..=65536).contains(&taps) || !taps.is_multiple_of(2) {
        return Err(format!("taps 需为 64..=65536 的偶数，当前 {taps}"));
    }
    let n = taps;
    let nyquist = sample_rate as f32 / 2.0;

    let mut planner = RealFftPlanner::<f32>::new();
    let ifft = planner.plan_fft_inverse(n);
    let mut spectrum = vec![Complex32::new(0.0, 0.0); n / 2 + 1];

    let delay = (n - 1) as f32 / 2.0;
    for (k, bin) in spectrum.iter_mut().enumerate() {
        let f = k as f32 * sample_rate as f32 / n as f32;
        if f > nyquist {
            break;
        }
        let db = interpolate_log_points(freqs, corr_db, f.max(freqs[0]));
        let mag = 10f32.powf(db / 20.0);
        let phase = -2.0 * std::f32::consts::PI * f * delay / sample_rate as f32;
        *bin = Complex32::new(mag * phase.cos(), mag * phase.sin());
    }
    // DC / Nyquist 必须为实数
    spectrum[0].im = 0.0;
    if let Some(last) = spectrum.last_mut() {
        last.im = 0.0;
    }

    let mut scratch = vec![Complex32::new(0.0, 0.0); ifft.get_scratch_len()];
    let mut out = vec![0.0f32; n];
    ifft.process_with_scratch(&mut spectrum, &mut out, &mut scratch)
        .map_err(|e| format!("IFFT 失败: {e:?}"))?;
    // realfft 逆变换不带 1/N 归一化
    let norm = 1.0 / n as f32;
    for s in out.iter_mut() {
        *s *= norm;
    }

    // Hann 窗（峰值在中心 N/2）
    let center = n as f32 / 2.0;
    for (i, s) in out.iter_mut().enumerate() {
        let x = (i as f32 - center) / center * std::f32::consts::PI;
        let w = if x.abs() <= std::f32::consts::PI {
            0.5 * (1.0 + x.cos())
        } else {
            0.0
        };
        *s *= w;
    }
    Ok(out)
}

/// 单点 log-线性插值（内部辅助）
fn interpolate_log_points(freqs: &[f32], values: &[f32], f: f32) -> f32 {
    let first = freqs[0];
    let last = freqs[freqs.len() - 1];
    if f <= first {
        return values[0];
    }
    if f >= last {
        return values[values.len() - 1];
    }
    let lf = f.ln();
    let mut lo = 0usize;
    let mut hi = freqs.len() - 1;
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        if freqs[mid].ln() <= lf {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let t = (lf - freqs[lo].ln()) / (freqs[hi].ln() - freqs[lo].ln());
    values[lo] + t * (values[hi] - values[lo])
}

/// 主入口：解析 REW 文本 → 生成校正 IR。
///
/// `target_sample_rate` 必须与 DSP 管线输出采样率一致（否则频响错位）。
pub fn generate_correction(
    rew_txt: &str,
    cfg: &CorrectionConfig,
    target_sample_rate: u32,
) -> Result<CorrectionReport, String> {
    if target_sample_rate == 0 {
        return Err("无效的目标采样率".into());
    }
    let points = parse_rew_txt(rew_txt)?;

    // 频率栅格：对数等间距，覆盖 10Hz ~ Nyquist
    let grid_n = 1024;
    let nyquist = target_sample_rate as f32 / 2.0;
    let f_max = nyquist.min(20000.0);
    let f_min = 10.0f32;
    let ratio = (f_max / f_min).powf(1.0 / (grid_n - 1) as f32);
    let freqs: Vec<f32> = (0..grid_n).map(|i| f_min * ratio.powi(i)).collect();

    let mut measured = interpolate_log(&points, &freqs);
    smooth_octave(&mut measured, &freqs, cfg.smoothing_octave);
    let corr = correction_curve(&freqs, &measured, cfg);
    let mut ir = design_fir(&freqs, &corr, cfg.taps, target_sample_rate)?;

    // 峰值归一化到 headroom，并计算应用的增益
    let peak = ir.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
    let applied_gain_db = if peak > 1e-12 {
        let target = 10f32.powf(-cfg.headroom_db / 20.0);
        let scale = target / peak;
        for s in ir.iter_mut() {
            *s *= scale;
        }
        20.0 * scale.log10()
    } else {
        // 全零 IR（理论上不会发生）：退化为单位冲激
        let center_idx = ir.len() / 2;
        ir[center_idx] = 10f32.powf(-cfg.headroom_db / 20.0);
        -cfg.headroom_db
    };

    Ok(CorrectionReport {
        ir,
        sample_rate: target_sample_rate,
        applied_gain_db,
        points: points.len(),
    })
}

/// 导出 IR 为 32-bit float WAV（单声道），供 `ConvolutionEq::load_wav` 加载
pub fn export_ir_wav(ir: &[f32], sample_rate: u32, path: &str) -> Result<(), String> {
    if ir.is_empty() {
        return Err("IR 为空".into());
    }
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(path, spec).map_err(|e| format!("创建 WAV 失败: {e}"))?;
    for &s in ir {
        writer.write_sample(s).map_err(|e| format!("写入 WAV 失败: {e}"))?;
    }
    writer.finalize().map_err(|e| format!("收尾 WAV 失败: {e}"))?;
    Ok(())
}

/// 离线重采样单声道 IR（rubato SincFixedOut，与解码链路同款 SRC）。
///
/// `ConvolutionEq::load_wav` 在 IR 采样率与管线采样率不一致时调用；
/// 也可用于将已有 IR WAV 适配到目标输出采样率。
pub fn resample_ir(ir: &[f32], src_rate: u32, dst_rate: u32) -> Result<Vec<f32>, String> {
    if ir.is_empty() {
        return Err("IR 为空".into());
    }
    if src_rate == 0 || dst_rate == 0 {
        return Err("无效采样率".into());
    }
    if (src_rate as i64 - dst_rate as i64).abs() <= 1 {
        return Ok(ir.to_vec());
    }
    use rubato::{InterpolationParameters, InterpolationType, Resampler, SincFixedOut, WindowFunction};
    let params = InterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: InterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };
    let mut resampler = SincFixedOut::<f64>::new(dst_rate as f64 / src_rate as f64, params, 1024, 1);
    let input: Vec<f64> = ir.iter().map(|&s| s as f64).collect();
    let mut out: Vec<f64> = Vec::new();
    let mut buf = [input];
    loop {
        let needed = resampler.nbr_frames_needed();
        if buf[0].len() < needed {
            break;
        }
        let waves_in: Vec<Vec<f64>> = vec![buf[0].drain(..needed).collect()];
        match resampler.process(&waves_in) {
            Ok(waves_out) => out.extend_from_slice(&waves_out[0]),
            Err(e) => return Err(format!("IR 重采样失败: {e:?}")),
        }
    }
    // 尾部残余：补零到所需长度再处理一次（补零不改变 IR 有效内容）
    if !buf[0].is_empty() {
        let needed = resampler.nbr_frames_needed();
        buf[0].resize(needed, 0.0);
        let waves_in: Vec<Vec<f64>> = vec![buf[0].drain(..needed).collect()];
        if let Ok(waves_out) = resampler.process(&waves_in) {
            out.extend_from_slice(&waves_out[0]);
        }
    }
    if out.is_empty() {
        return Err("IR 重采样结果为空".into());
    }
    // SincFixedOut 按固定输出块产出，截断到理论长度
    let expected = (ir.len() as f64 * dst_rate as f64 / src_rate as f64).round() as usize;
    out.truncate(expected.max(1));
    Ok(out.iter().map(|&s| s as f32).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 直接 DTFT 求 FIR 在指定频率的幅频响应（dB）。
    /// 测试专用：O(N) 逐点求和，避免 FFT 频率栅格对不齐被测频点。
    fn fir_magnitude_db(ir: &[f32], freq: f32, sample_rate: f32) -> f32 {
        let w = 2.0 * std::f64::consts::PI * freq as f64 / sample_rate as f64;
        let mut re = 0.0f64;
        let mut im = 0.0f64;
        for (n, &h) in ir.iter().enumerate() {
            re += h as f64 * (w * n as f64).cos();
            im -= h as f64 * (w * n as f64).sin();
        }
        let mag = (re * re + im * im).sqrt();
        (20.0 * mag.max(1e-12).log10()) as f32
    }

    /// 合成 REW 文本：base 平直 + 若干峰/谷
    fn synth_rew(peaks: &[(f32, f32)]) -> String {
        let mut out = String::from("* Room EQ Wizard export (synthetic)\n");
        out.push_str("Freq (Hz), Level (dB), Phase (deg)\n");
        // 1/24 octave 栅格，20Hz~20kHz
        let mut f = 20.0f32;
        while f <= 20000.0 {
            let mut level = 0.0f32;
            for &(pf, gain) in peaks {
                // 类峰形：高斯型（log 域），Q≈6 的窄带
                let d = (f / pf).ln();
                level += gain * (-d * d * 60.0).exp();
            }
            out.push_str(&format!("{f:.2}, {level:.3}, 0.0\n"));
            f *= 2f32.powf(1.0 / 24.0);
        }
        out
    }

    // ── 解析 ──

    #[test]
    fn test_parse_rew_basic() {
        let txt = "* comment\nFreq (Hz), Level (dB)\n20.0, -1.5\n100.0, 2.3\n1000.0, 0.1\n";
        let pts = parse_rew_txt(txt).unwrap();
        assert_eq!(pts.len(), 3);
        assert_eq!(pts[0].freq, 20.0);
        assert!((pts[1].level_db - 2.3).abs() < 1e-6);
    }

    #[test]
    fn test_parse_rew_tab_separated_no_header() {
        let txt = "20\t-1.0\n1000\t0.5\n8000\t-2.0\n";
        let pts = parse_rew_txt(txt).unwrap();
        assert_eq!(pts.len(), 3);
    }

    #[test]
    fn test_parse_rew_unsorted_and_malformed() {
        let txt = "Freq (Hz), Level (dB)\n1000.0, 1.0\nbad, x\n20.0, -1.0\n50.0\n1000.0, 9.9\n";
        let pts = parse_rew_txt(txt).unwrap();
        // bad 行跳过、"50.0" 单列跳过、重复 1000Hz 去重
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0].freq, 20.0);
        assert_eq!(pts[1].freq, 1000.0);
    }

    #[test]
    fn test_parse_rew_empty_and_insufficient() {
        assert!(parse_rew_txt("").is_err());
        assert!(parse_rew_txt("* only comments\n").is_err());
        assert!(parse_rew_txt("Freq, Level\n20.0, 0.0\n").is_err());
    }

    // ── 恒等：平直测量 → 单位冲激响应 ──

    #[test]
    fn test_flat_measurement_yields_identity() {
        let cfg = CorrectionConfig::default();
        let report = generate_correction(&synth_rew(&[]), &cfg, 44100).unwrap();
        assert_eq!(report.ir.len(), cfg.taps);
        // 全频段 |H(f)| ≈ 0dB（归一化后为 -headroom，补偿回去）
        let offset = report.applied_gain_db;
        for &f in &[50.0, 200.0, 1000.0, 5000.0, 15000.0] {
            let mag = fir_magnitude_db(&report.ir, f, 44100.0) - offset;
            assert!(mag.abs() < 0.5, "{f}Hz 响应应平坦: {mag}dB");
        }
        // 冲激响应能量集中在中心
        let center = cfg.taps / 2;
        let total_e: f32 = report.ir.iter().map(|s| s * s).sum();
        let center_e: f32 = report.ir[center - 32..center + 32].iter().map(|s| s * s).sum();
        assert!(center_e / total_e > 0.95, "能量应集中于中心: {}/{}", center_e, total_e);
    }

    // ── 校正效果：峰被压平，null 受限幅保护 ──

    #[test]
    fn test_peak_corrected_null_limited() {
        // 120Hz 有 +8dB 房间模式峰，300Hz 有 -8dB null
        let txt = synth_rew(&[(120.0, 8.0), (300.0, -8.0)]);
        let cfg = CorrectionConfig::default();
        let report = generate_correction(&txt, &cfg, 44100).unwrap();
        let offset = report.applied_gain_db;

        // 120Hz 峰：校正后应被衰减约 -8dB（限幅 max_cut_db 内）
        let mag120 = fir_magnitude_db(&report.ir, 120.0, 44100.0) - offset;
        assert!(mag120 < -4.0, "120Hz 峰应被衰减: 校正增益 {mag120}dB");
        assert!(mag120 > -10.0, "120Hz 不应过校正: {mag120}dB");

        // 300Hz null：补偿不超过 null_limit_db (3dB)，且确实有提升
        let mag300 = fir_magnitude_db(&report.ir, 300.0, 44100.0) - offset;
        assert!(mag300 <= cfg.null_limit_db + 0.5, "null 补偿应受限: {mag300}dB");
        assert!(mag300 > 1.0, "null 处应有受限提升: {mag300}dB");

        // 1kHz 参考点：无偏差 → 校正增益 ≈ 0
        let mag1k = fir_magnitude_db(&report.ir, 1000.0, 44100.0) - offset;
        assert!(mag1k.abs() < 1.0, "1kHz 无偏差处应接近 0dB: {mag1k}dB");
    }

    #[test]
    fn test_correction_limits_null_boost() {
        // 整体下陷 -10dB 的测量 → null 提升受 null_limit_db 限制
        let mut txt = String::from("Freq (Hz), Level (dB)\n");
        let mut f = 20.0f32;
        while f <= 20000.0 {
            txt.push_str(&format!("{f:.2}, -10.0\n"));
            f *= 2f32.powf(1.0 / 24.0);
        }
        let cfg = CorrectionConfig::default();
        let report = generate_correction(&txt, &cfg, 44100).unwrap();
        let offset = report.applied_gain_db;
        let mag = fir_magnitude_db(&report.ir, 500.0, 44100.0) - offset;
        // 理想提升 +10dB，受 null_limit_db (3dB) + 频段权重限制
        assert!(mag <= cfg.null_limit_db + 1.0, "null 提升应受限: {mag}dB");
        assert!(mag > 0.0, "整体下陷应得到提升: {mag}dB");
    }

    #[test]
    fn test_out_of_range_untouched() {
        // 120Hz 峰，但校正范围设为 200Hz 起 → 120Hz 不被校正
        let txt = synth_rew(&[(120.0, 8.0)]);
        let cfg = CorrectionConfig {
            freq_range: (200.0, 16000.0),
            ..CorrectionConfig::default()
        };
        let report = generate_correction(&txt, &cfg, 44100).unwrap();
        let offset = report.applied_gain_db;
        let mag120 = fir_magnitude_db(&report.ir, 120.0, 44100.0) - offset;
        assert!(mag120.abs() < 1.0, "范围外 120Hz 应不被校正: {mag120}dB");
    }

    #[test]
    fn test_headroom_normalization() {
        let cfg = CorrectionConfig::default();
        let report = generate_correction(&synth_rew(&[]), &cfg, 44100).unwrap();
        let peak = report.ir.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
        let expected = 10f32.powf(-cfg.headroom_db / 20.0);
        assert!((peak - expected).abs() < 1e-4, "峰值应归一化到 headroom: {peak} vs {expected}");
    }

    // ── WAV 导出往返 ──

    #[test]
    fn test_export_and_read_roundtrip() {
        let cfg = CorrectionConfig::default();
        let report = generate_correction(&synth_rew(&[]), &cfg, 44100).unwrap();
        let path = "/tmp/_test_room_correction_ir.wav";
        export_ir_wav(&report.ir, 44100, path).unwrap();

        let mut reader = hound::WavReader::open(path).unwrap();
        assert_eq!(reader.spec().sample_rate, 44100);
        assert_eq!(reader.spec().channels, 1);
        let read: Vec<f32> = reader.samples::<f32>().map(|s| s.unwrap()).collect();
        assert_eq!(read.len(), report.ir.len());
        let max_diff = read
            .iter()
            .zip(report.ir.iter())
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        assert!(max_diff < 1e-6, "往返误差过大: {max_diff}");
        std::fs::remove_file(path).ok();
    }

    // ── 重采样一致性（配合 ConvolutionEq 的 IR 重采样）──

    #[test]
    fn test_resampled_ir_preserves_response() {
        // 带 120Hz 校正的 48kHz IR 重采样到 44.1kHz，低频校正效果应保留；
        // 探针选在校正区内（避开频域采样旁瓣泄漏区）
        let txt = synth_rew(&[(120.0, 6.0)]);
        let cfg = CorrectionConfig::default();
        let r48 = generate_correction(&txt, &cfg, 48000).unwrap();
        let resampled = resample_ir(&r48.ir, 48000, 44100).unwrap();
        // 长度比例应接近采样率比例
        let ratio = resampled.len() as f32 / r48.ir.len() as f32;
        assert!((ratio - 44100.0 / 48000.0).abs() < 0.02, "长度比例异常: {ratio}");

        // 重采样保持绝对幅度不变，直接比较原始幅值（不做峰值归一：
        // sinc 插值可能在样本间产生合法过冲，峰值不是稳定参考系）
        let m48 = fir_magnitude_db(&r48.ir, 120.0, 48000.0);
        let m44 = fir_magnitude_db(&resampled, 120.0, 44100.0);
        assert!(
            (m48 - m44).abs() < 1.5,
            "重采样后 120Hz 响应偏差过大: {}dB vs {}dB",
            m48,
            m44
        );
        // 两者都应表现为衰减（120Hz 是校正峰）
        assert!(m48 < -1.0, "48k IR 的 120Hz 应被衰减: {m48}dB");
        assert!(m44 < -1.0, "重采样后 120Hz 应仍被衰减: {m44}dB");
    }

    #[test]
    fn test_resample_ir_same_rate_noop() {
        let ir = vec![0.0, 1.0, 0.0, -0.5];
        assert_eq!(resample_ir(&ir, 44100, 44100).unwrap(), ir);
        assert!(resample_ir(&[], 44100, 48000).is_err());
    }
}
