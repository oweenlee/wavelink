//! 解码器（Symphonia 流式解码 + DSD 文件直解）
//!
//! 元数据/封面/格式探测见 [`metadata`]（经 re-export 仍可从 `decoder::` 路径访问）。

pub mod metadata;
pub use metadata::*;

use std::fs::File;

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crossbeam_channel::{bounded, unbounded, Receiver, SendTimeoutError, Sender};
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::codecs::registry::RegisterableAudioDecoder;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use tracing::{debug, error, info, warn};

use rubato::{InterpolationParameters, InterpolationType, Resampler, SincFixedOut, WindowFunction};

use crate::dsd;
use crate::EngineEvent;
use crate::error::EngineError;

/// 解码器输出 channel 容量（帧数），利用 crossbeam 背压阻塞避免内存无限增长
const DECODE_CHANNEL_CAPACITY: usize = 8;

/// 解码输出的一帧 PCM 数据。
pub struct DecodedFrame {
    /// 交错 PCM f32 样本（L/R/L/R/...）
    pub samples: Vec<f32>,
    /// 本帧在音频流中的时间位置（秒）
    pub pts_secs: f64,
    /// 输出采样率（通常 44100）
    pub sample_rate: u32,
    /// 输出声道数（通常 2）
    pub channels: u32,
}

/// 流式解码器。后台线程持续解码，通过 crossbeam channel 逐帧输出。
/// 用法：`Decoder::start(path, sr, ch, pos, seek, end) → (rx, handle)`  
pub struct Decoder {
    tx: Option<Sender<()>>,
    handle: Option<JoinHandle<()>>,
    /// 解码进度（已输出样本数），可被外部读取
    pub position: Arc<AtomicU64>,
    /// 解码错误接收端（后台线程解码失败时发送）
    err_rx: Option<Receiver<EngineError>>,
}

impl Decoder {
    /// 取走解码错误（非阻塞）。后台解码线程失败时通过此方法获取具体原因。
    pub fn take_decode_error(&self) -> Option<EngineError> {
        self.err_rx.as_ref().and_then(|rx| rx.try_recv().ok())
    }

    /// 取走错误接收端（用于传递给消费者线程，取走后 take_decode_error 不再可用）
    pub(crate) fn take_err_rx(&mut self) -> Option<Receiver<EngineError>> {
        self.err_rx.take()
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        self.stop();
        if let Some(h) = self.handle.take() {
            if h.thread().id() != std::thread::current().id() {
                let _ = h.join();
            }
        }
    }
}

impl Decoder {
    /// 启动后台解码线程。返回 (帧接收器, 解码器句柄)。
    /// - `path` — 音频文件路径
    /// - `target_rate` / `target_channels` — 输出重采样目标
    /// - `position` — 外部可读的解码进度（样本数）
    /// - `seek_pos` — 可选起始位置（秒）
    /// - `end_secs` — 可选结束位置（秒），到达后停止解码（CUE 分轨用）
    pub fn start(
        path: &Path,
        target_rate: u32,
        target_channels: u32,
        position: Arc<AtomicU64>,
        seek_pos: Option<f64>,
        end_secs: Option<f64>,
    ) -> Result<(Receiver<DecodedFrame>, Self), EngineError> {
        let (tx, rx) = bounded(DECODE_CHANNEL_CAPACITY);
        let (stx, srx) = unbounded();
        let (err_tx, err_rx) = bounded::<EngineError>(1);
        let p = path.to_path_buf();
        let pos_clone = position.clone();
        let handle = thread::spawn(move || {
            crate::engine::thread_priority::elevate_audio_thread();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run(
                    &p,
                    target_rate,
                    target_channels,
                    tx,
                    srx,
                    position,
                    seek_pos,
                    end_secs,
                )
            }));
            match result {
                Ok(Err(e)) => {
                    error!("解码失败: {e}");
                    let _ = err_tx.send(e);
                }
                Err(panic_info) => {
                    let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                        s.to_string()
                    } else if let Some(s) = panic_info.downcast_ref::<String>() {
                        s.clone()
                    } else {
                        "解码线程未知 panic".to_string()
                    };
                    error!("解码线程 crash: {msg}");
                    let _ = err_tx.send(EngineError::DecodeFailed {
                        path: p.clone(),
                        reason: msg,
                    });
                }
                Ok(Ok(())) => {}
            }
        });
        Ok((
            rx,
            Decoder {
                tx: Some(stx),
                handle: Some(handle),
                position: pos_clone,
                err_rx: Some(err_rx),
            },
        ))
    }

    /// 以 DoP（DSD over PCM）方式启动 DSD 解码线程。
    ///
    /// 原始 DSD 比特流打包为 DoP PCM（采样率 = DSD 速率 / 16），
    /// 不做 DSD→PCM 转换、不重采样、不过 DSP，交给支持 DoP 的 DAC 还原原生 DSD。
    /// - `left_justify` — 输出格式为 32-bit 整数时传 true（24-bit 字左对齐），24-bit/浮点传 false
    /// - `target_channels` — 期望声道数（通常用源文件声道数）
    pub fn start_dop(
        path: &Path,
        left_justify: bool,
        target_channels: u32,
        position: Arc<AtomicU64>,
        seek_pos: Option<f64>,
        end_secs: Option<f64>,
    ) -> Result<(Receiver<DecodedFrame>, Self), EngineError> {
        let (tx, rx) = bounded(DECODE_CHANNEL_CAPACITY);
        let (stx, srx) = unbounded();
        let (err_tx, err_rx) = bounded::<EngineError>(1);
        let p = path.to_path_buf();
        let pos_clone = position.clone();
        let handle = thread::spawn(move || {
            crate::engine::thread_priority::elevate_audio_thread();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run_dsd_dop(
                    &p,
                    left_justify,
                    target_channels,
                    tx,
                    srx,
                    seek_pos,
                    end_secs,
                )
            }));
            match result {
                Ok(Err(e)) => {
                    error!("DoP 解码失败: {e}");
                    let _ = err_tx.send(e);
                }
                Err(panic_info) => {
                    let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                        s.to_string()
                    } else if let Some(s) = panic_info.downcast_ref::<String>() {
                        s.clone()
                    } else {
                        "DoP 解码线程未知 panic".to_string()
                    };
                    error!("DoP 解码线程 crash: {msg}");
                    let _ = err_tx.send(EngineError::DecodeFailed {
                        path: p.clone(),
                        reason: msg,
                    });
                }
                Ok(Ok(())) => {}
            }
        });
        Ok((
            rx,
            Decoder {
                tx: Some(stx),
                handle: Some(handle),
                position: pos_clone,
                err_rx: Some(err_rx),
            },
        ))
    }

    /// 停止后台解码线程
    pub fn stop(&self) {
        if let Some(ref t) = self.tx {
            let _ = t.send(());
        }
    }

    /// 从流式数据源启动解码（网络流媒体用）。
    ///
    /// - `source` — 平台层写入字节流的 `StreamMediaSource`
    /// - `target_rate` / `target_channels` — 输出重采样目标
    /// - `position` — 外部可读的解码进度
    /// - `format_hint` — 可选格式提示（如 "mp3", "flac", "aac"），帮助 Symphonia 探测
    pub fn start_from_stream(
        source: crate::stream::StreamMediaSource,
        target_rate: u32,
        target_channels: u32,
        position: Arc<AtomicU64>,
        format_hint: Option<String>,
        event_tx: Sender<EngineEvent>,
        bytes_consumed: Arc<AtomicU64>,
    ) -> Result<(Receiver<DecodedFrame>, Self), EngineError> {
        let (tx, rx) = bounded(DECODE_CHANNEL_CAPACITY);
        let (stx, srx) = unbounded();
        let (err_tx, err_rx) = bounded::<EngineError>(1);
        let pos_clone = position.clone();
        let handle = thread::spawn(move || {
            crate::engine::thread_priority::elevate_audio_thread();
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run_from_stream(
                    source,
                    target_rate,
                    target_channels,
                    tx,
                    srx,
                    position,
                    format_hint,
                    event_tx,
                    bytes_consumed,
                )
            }));
            match result {
                Ok(Err(e)) => {
                    error!("流式解码失败: {e}");
                    let _ = err_tx.send(e);
                }
                Err(panic_info) => {
                    let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                        s.to_string()
                    } else if let Some(s) = panic_info.downcast_ref::<String>() {
                        s.clone()
                    } else {
                        "流式解码线程未知 panic".to_string()
                    };
                    error!("流式解码线程 crash: {msg}");
                    let _ = err_tx.send(EngineError::DecodeFailed {
                        path: "stream".into(),
                        reason: msg,
                    });
                }
                Ok(Ok(())) => {}
            }
        });
        Ok((
            rx,
            Decoder {
                tx: Some(stx),
                handle: Some(handle),
                position: pos_clone,
                err_rx: Some(err_rx),
            },
        ))
    }
}

/// 有界 channel 发送：利用 crossbeam 背压阻塞，每 10ms 检查 stop 信号避免死锁
fn try_send_or_stop(tx: &Sender<DecodedFrame>, frame: DecodedFrame, stop_rx: &Receiver<()>) {
    let mut frame = frame;
    loop {
        match tx.send_timeout(frame, Duration::from_millis(10)) {
            Ok(()) => return,
            Err(SendTimeoutError::Timeout(f)) => {
                frame = f;
                if !stop_rx.is_empty() {
                    return;
                }
            }
            Err(SendTimeoutError::Disconnected(_)) => return,
        }
    }
}

/// 创建 rubato 重采样器（如源/目标采样率不同）
fn create_resampler(src_rate: u32, target_rate: u32, out_ch: usize) -> Option<SincFixedOut<f64>> {
    if (src_rate as i64 - target_rate as i64).abs() <= 1 {
        return None;
    }
    let params = InterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: InterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };
    Some(SincFixedOut::<f64>::new(
        target_rate as f64 / src_rate as f64,
        params,
        1024,
        out_ch,
    ))
}

/// 重采样并发送（或直发）。返回更新后的 pts。
fn resample_and_send(
    mixed: &[f32],
    resampler: &mut Option<SincFixedOut<f64>>,
    rubato_buf: &mut [Vec<f64>],
    out_ch: usize,
    target_rate: u32,
    target_ch: u32,
    pts: f64,
    tx: &Sender<DecodedFrame>,
    stop_rx: &Receiver<()>,
) -> f64 {
    if let Some(ref mut resampler) = resampler {
        for c in 0..out_ch {
            rubato_buf[c].extend(mixed.iter().skip(c).step_by(out_ch).map(|&s| s as f64));
        }
        let mut cur_pts = pts;
        loop {
            let needed = resampler.nbr_frames_needed();
            if rubato_buf[0].len() < needed {
                break;
            }
            let waves_in: Vec<Vec<f64>> = rubato_buf
                .iter_mut()
                .map(|buf| buf.drain(..needed).collect())
                .collect();
            match resampler.process(&waves_in) {
                Ok(waves_out) => {
                    let out_frames = waves_out[0].len();
                    let mut samples = Vec::with_capacity(out_frames * out_ch);
                    for f in 0..out_frames {
                        for c in 0..out_ch {
                            samples.push(waves_out[c][f] as f32);
                        }
                    }
                    try_send_or_stop(
                        tx,
                        DecodedFrame {
                            samples,
                            pts_secs: cur_pts,
                            sample_rate: target_rate,
                            channels: target_ch,
                        },
                        stop_rx,
                    );
                    cur_pts += out_frames as f64 / target_rate as f64;
                }
                Err(e) => warn!("rubato 重采样失败: {e:?}"),
            }
        }
        cur_pts
    } else {
        try_send_or_stop(
            tx,
            DecodedFrame {
                samples: mixed.to_vec(),
                pts_secs: pts,
                sample_rate: target_rate,
                channels: target_ch,
            },
            stop_rx,
        );
        pts + (mixed.len() / out_ch) as f64 / target_rate as f64
    }
}

/// EOF 时冲刷重采样器：`SincFixedOut` 按固定块消费输入，残余不足一个块的
/// 输入帧若不处理会在曲尾被静默丢弃（44.1k↔48k 时约 24ms）。补零到所需
/// 长度做最后一次 `process`，把剩余有效音频连同滤波器尾部一起输出。
fn flush_resampler(
    resampler: &mut Option<SincFixedOut<f64>>,
    rubato_buf: &mut [Vec<f64>],
    out_ch: usize,
    target_rate: u32,
    target_ch: u32,
    pts: f64,
    tx: &Sender<DecodedFrame>,
    stop_rx: &Receiver<()>,
) {
    let Some(ref mut resampler) = resampler else {
        return;
    };
    if stop_rx.try_recv().is_ok() || rubato_buf.iter().all(|b| b.is_empty()) {
        return;
    }
    let needed = resampler.nbr_frames_needed();
    for buf in rubato_buf.iter_mut() {
        buf.resize(needed, 0.0);
    }
    let waves_in: Vec<Vec<f64>> = rubato_buf.iter_mut().map(std::mem::take).collect();
    if let Ok(waves_out) = resampler.process(&waves_in) {
        let out_frames = waves_out[0].len();
        let mut samples = Vec::with_capacity(out_frames * out_ch);
        for f in 0..out_frames {
            for c in 0..out_ch {
                samples.push(waves_out[c][f] as f32);
            }
        }
        try_send_or_stop(
            tx,
            DecodedFrame {
                samples,
                pts_secs: pts,
                sample_rate: target_rate,
                channels: target_ch,
            },
            stop_rx,
        );
    }
}

fn run(
    path: &Path,
    target_rate: u32,
    target_ch: u32,
    tx: Sender<DecodedFrame>,
    stop_rx: Receiver<()>,
    _position: Arc<AtomicU64>,
    seek_pos: Option<f64>,
    end_secs: Option<f64>,
) -> Result<(), EngineError> {
    // 绕过 Symphonia 直解：DSD
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        if ext.eq_ignore_ascii_case("dsf") || ext.eq_ignore_ascii_case("dff") {
            return run_dsd(
                path,
                target_rate,
                target_ch,
                tx,
                stop_rx,
                seek_pos,
                end_secs,
            );
        }
        // WavPack 无可用 Rust 解码器（Symphonia 上游亦不支持），明确报错而非“探测失败”
        if ext.eq_ignore_ascii_case("wv") || ext.eq_ignore_ascii_case("wvc") {
            return Err(EngineError::DecodeFailed {
                path: path.to_path_buf(),
                reason: "暂不支持 WavPack (.wv) 格式".into(),
            });
        }
        // APE (Monkey's Audio)：Symphonia 不支持，用纯 Rust ape-decoder 直解
        if ext.eq_ignore_ascii_case("ape") {
            return run_ape(
                path,
                target_rate,
                target_ch,
                tx,
                stop_rx,
                seek_pos,
                end_secs,
            );
        }
    }

    let file = File::open(path).map_err(|_| EngineError::FileNotFound(path.to_path_buf()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            mss,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|e| EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: format!("探测失败: {e}"),
        })?;
    let (track_id, audio_cp) = {
        let track =
            format
                .default_track(TrackType::Audio)
                .ok_or_else(|| EngineError::DecodeFailed {
                    path: path.to_path_buf(),
                    reason: "无音频轨".into(),
                })?;
        let cp = match &track.codec_params {
            Some(symphonia::core::codecs::CodecParameters::Audio(a)) => a.clone(),
            _ => {
                return Err(EngineError::DecodeFailed {
                    path: path.to_path_buf(),
                    reason: "非音频编解码参数".into(),
                })
            }
        };
        (track.id, cp)
    };
    let src_rate = audio_cp.sample_rate.unwrap_or(44100);
    let src_ch = audio_cp.channels.as_ref().map(|c| c.count()).unwrap_or(2) as u32;
    info!("解码: {} ({}Hz, {}ch)", path.display(), src_rate, src_ch);

    // 先尝试默认 codecs，失败则降级到 Opus 适配器
    let mut decoder = match symphonia::default::get_codecs()
        .make_audio_decoder(&audio_cp, &AudioDecoderOptions::default())
    {
        Ok(d) => d,
        Err(_) => match symphonia_adapter_oporus::OpusDecoder::try_registry_new(
            &audio_cp,
            &AudioDecoderOptions::default(),
        ) {
            Ok(d) => {
                info!("使用 Opus 适配器解码");
                d
            }
            Err(e) => {
                return Err(EngineError::DecodeFailed {
                    path: path.to_path_buf(),
                    reason: format!("创建解码器失败: {e}"),
                })
            }
        },
    };

    // 跳转到指定时间位置
    if let Some(secs) = seek_pos {
        // 先用 format.seek() 尝试精确跳转
        let seek_time = symphonia::core::units::Time::try_from_secs_f64(secs)
            .unwrap_or(symphonia::core::units::Time::ZERO);
        let _seeked = format.seek(
            symphonia::core::formats::SeekMode::Accurate,
            symphonia::core::formats::SeekTo::Time {
                time: seek_time,
                track_id: Some(track_id),
            },
        );
        if _seeked.is_err() {
            debug!("format.seek() 不支持, 使用跳帧方式");
        }
        // 解码器状态在 seek 后需要重置，重建失败则终止（旧 decoder 状态已被 seek 污染）
        let new_dec = symphonia::default::get_codecs()
            .make_audio_decoder(&audio_cp, &AudioDecoderOptions::default())
            .or_else(|_| {
                symphonia_adapter_oporus::OpusDecoder::try_registry_new(
                    &audio_cp,
                    &AudioDecoderOptions::default(),
                )
            });
        match new_dec {
            Ok(d) => decoder = d,
            Err(e) => {
                return Err(EngineError::DecodeFailed {
                    path: path.to_path_buf(),
                    reason: format!("seek 后解码器重建失败: {e}"),
                })
            }
        }

        // 样本级精确 seek：format.seek() 只保证落在包边界（可能偏移几十 ms），
        // 继续解码并丢弃目标之前的残余样本。
        // 位置累计基于每个 packet 的 pts（绝对样本位置，WAV/FLAC 等由字节
        // 偏移或 granule 反推，可靠）；pts 缺失（个别格式）则退回相对累计，
        // 此时落点可能偏早几个包，但绝不丢过头。
        let target_total = (secs * src_rate as f64) as u64 * src_ch as u64;
        let mut consumed: u64 = 0; // 无 pts 时的相对累计
        while consumed < target_total {
            if stop_rx.try_recv().is_ok() {
                return Ok(());
            }
            let packet = match format.next_packet() {
                Ok(Some(pkt)) => pkt,
                _ => break, // EOF/错误：无更多数据可丢
            };
            if packet.track_id != track_id {
                continue;
            }
            // 用 packet.pts 校准累计位置为绝对交错样本下标。
            // 注意 pts 单位是帧（frame），不是样本，需乘声道数
            let pkt_start_abs = packet.pts.get() as u64 * src_ch as u64;
            if pkt_start_abs > consumed {
                consumed = pkt_start_abs;
            }
            let decoded = match decoder.decode(&packet) {
                Ok(buf) => buf,
                Err(_) => continue,
            };
            let n = (decoded.samples_interleaved() * decoded.spec().channels().count()) as u64;
            if consumed + n <= target_total {
                // 整包都在目标之前，直接丢弃（不解交错）
                consumed += n;
            } else {
                // 目标落在本包内：只保留目标之后的样本（saturating 防 pts 越界下溢）
                let drop = target_total.saturating_sub(consumed) as usize;
                let spec = decoded.spec().clone();
                let num_samples = decoded.samples_interleaved();
                let mut interleaved = vec![0.0f32; num_samples];
                decoded.copy_to_slice_interleaved(&mut interleaved);
                let kept: Vec<f32> = interleaved[drop.min(interleaved.len())..].to_vec();
                if !kept.is_empty() && kept.iter().all(|s| s.is_finite()) {
                    let in_ch = spec.channels().count();
                    let mixed = mix_channels(&kept, in_ch, target_ch as usize);
                    let out_ch = target_ch as usize;
                    let mut rubato_resampler = create_resampler(src_rate, target_rate, out_ch);
                    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];
                    let _ = resample_and_send(
                        &mixed,
                        &mut rubato_resampler,
                        &mut rubato_buf,
                        out_ch,
                        target_rate,
                        target_ch,
                        secs,
                        &tx,
                        &stop_rx,
                    );
                }
                break;
            }
        }
    }

    // ── 创建 rubato 重采样器（如有必要） ──
    let out_ch = target_ch as usize;
    let mut rubato_resampler = create_resampler(src_rate, target_rate, out_ch);
    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];
    let mut consecutive_errors = 0u32;
    // 跟踪最后发送帧的 pts，EOF 冲刷重采样器残余时用
    let mut last_pts = 0.0f64;

    loop {
        if stop_rx.try_recv().is_ok() {
            break;
        }
        let packet = match format.next_packet() {
            Ok(Some(pkt)) => pkt,
            Ok(None) => {
                debug!("EOF");
                break;
            }
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                debug!("EOF");
                break;
            }
            Err(e) => {
                debug!("结束: {e}");
                break;
            }
        };
        if packet.track_id != track_id {
            continue;
        }

        // end_secs 分段截断
        if let Some(end) = end_secs {
            if (packet.pts.get() as f64 / src_rate as f64) >= end {
                debug!("到达 end_secs={end}, 停止解码");
                break;
            }
        }

        let decoded = match decoder.decode(&packet) {
            Ok(buf) => {
                consecutive_errors = 0;
                buf
            }
            // IO 错误（读盘失败等）不可恢复，必须终止；continue 会热自旋
            Err(symphonia::core::errors::Error::IoError(e)) => {
                warn!("解码 IO 错误，终止: {e}");
                break;
            }
            Err(e) => {
                consecutive_errors += 1;
                if consecutive_errors >= 64 {
                    warn!("连续 {consecutive_errors} 包解码失败，文件可能损坏，终止: {e}");
                    break;
                }
                debug!("解码错误: {e}");
                continue;
            }
        };

        // 转 f32 交错
        let spec = decoded.spec().clone();
        let num_samples = decoded.samples_interleaved();
        let mut interleaved = vec![0.0f32; num_samples];
        decoded.copy_to_slice_interleaved(&mut interleaved);

        // 跳过含 NaN/Inf 的帧，防止噪声传播到 DSP 管线
        if interleaved.iter().any(|&s| !s.is_finite()) {
            debug!("解码帧含无效样本 (NaN/Inf)，跳过");
            continue;
        }

        let in_ch = spec.channels().count();

        // 声道混音（支持 5.1/7.1 正确 downmix）
        let mixed = mix_channels(&interleaved, in_ch, out_ch);

        // rubato 异步 SRC + 发送
        let pts = packet.pts.get() as f64 / src_rate as f64;
        last_pts = resample_and_send(
            &mixed,
            &mut rubato_resampler,
            &mut rubato_buf,
            out_ch,
            target_rate,
            target_ch,
            pts,
            &tx,
            &stop_rx,
        );
    }
    flush_resampler(
        &mut rubato_resampler,
        &mut rubato_buf,
        out_ch,
        target_rate,
        target_ch,
        last_pts,
        &tx,
        &stop_rx,
    );
    Ok(())
}

/// 流式解码：从 `StreamMediaSource` 读取字节流 → Symphonia 解码 → 重采样 → 发送
fn run_from_stream(
    source: crate::stream::StreamMediaSource,
    target_rate: u32,
    target_ch: u32,
    tx: Sender<DecodedFrame>,
    stop_rx: Receiver<()>,
    _position: Arc<AtomicU64>,
    format_hint: Option<String>,
    event_tx: Sender<EngineEvent>,
    bytes_consumed: Arc<AtomicU64>,
) -> Result<(), EngineError> {
    // 在 source 被 move 进 MediaSourceStream 之前取出 content_length，
    // 供后续时长估算使用。
    let content_length = source.content_length();
    let mss = MediaSourceStream::new(Box::new(source), Default::default());
    let mut hint = Hint::new();
    if let Some(ref ext) = format_hint {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            mss,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|e| {
            // probe 失败多为「远端字节不足/非音频数据/连接中断」，原始
            // symphonia 报错对用户不可读，包装常见场景辅助定位
            let reason = format!("流式探测失败: {e}");
            error!("{reason}");
            EngineError::DecodeFailed {
                path: "stream".into(),
                reason: if e.to_string().contains("no suitable format reader") {
                    "远端数据不是可播放的音频，或字节流尚未就绪（连接/格式问题）".into()
                } else {
                    reason
                },
            }
        })?;
    let (track_id, audio_cp) = {
        let track =
            format
                .default_track(TrackType::Audio)
                .ok_or_else(|| EngineError::DecodeFailed {
                    path: "stream".into(),
                    reason: "无音频轨".into(),
                })?;
        let cp = match &track.codec_params {
            Some(symphonia::core::codecs::CodecParameters::Audio(a)) => a.clone(),
            _ => {
                return Err(EngineError::DecodeFailed {
                    path: "stream".into(),
                    reason: "非音频编解码参数".into(),
                })
            }
        };
        (track.id, cp)
    };
    let src_rate = audio_cp.sample_rate.unwrap_or(44100);
    let out_ch = target_ch as usize;
    info!("流式解码: {}Hz, hint={:?}", src_rate, format_hint);

    // 流总时长采用「渐进式」估算（见解码循环内）：用「已消费字节 / 已解码秒数」
    // 得到真实平均码率，再反推总时长 = content_length / 平均码率。
    // 不在此处用固定公式上报——probe 阶段无法得知真实编码码率，固定公式对
    // 压缩格式（FLAC/MP3/AAC…）只是粗略上界，反而会误导进度条。
    let mut dur_est: Option<f64> = None;
    let mut dur_est_sent = Instant::now();

    let mut decoder = match symphonia::default::get_codecs()
        .make_audio_decoder(&audio_cp, &AudioDecoderOptions::default())
    {
        Ok(d) => d,
        Err(_) => match symphonia_adapter_oporus::OpusDecoder::try_registry_new(
            &audio_cp,
            &AudioDecoderOptions::default(),
        ) {
            Ok(d) => {
                info!("流式: 使用 Opus 适配器解码");
                d
            }
            Err(e) => {
                return Err(EngineError::DecodeFailed {
                    path: "stream".into(),
                    reason: format!("创建解码器失败: {e}"),
                })
            }
        },
    };

    let mut rubato_resampler = create_resampler(src_rate, target_rate, out_ch);
    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];
    let mut consecutive_errors = 0u32;
    // 跟踪最后发送帧的 pts，EOF 冲刷重采样器残余时用
    let mut last_pts = 0.0f64;

    loop {
        if stop_rx.try_recv().is_ok() {
            break;
        }
        let packet = match format.next_packet() {
            Ok(Some(pkt)) => pkt,
            Ok(None) => {
                debug!("流式 EOF");
                break;
            }
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                debug!("流式 EOF");
                break;
            }
            Err(e) => {
                debug!("流式结束: {e}");
                break;
            }
        };
        if packet.track_id != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(buf) => {
                consecutive_errors = 0;
                buf
            }
            Err(symphonia::core::errors::Error::IoError(e)) => {
                warn!("流式 IO 错误，终止: {e}");
                break;
            }
            Err(e) => {
                consecutive_errors += 1;
                if consecutive_errors >= 64 {
                    warn!("流式连续 {consecutive_errors} 包解码失败，终止: {e}");
                    break;
                }
                debug!("流式解码错误: {e}");
                continue;
            }
        };

        let spec = decoded.spec().clone();
        let num_samples = decoded.samples_interleaved();
        let mut interleaved = vec![0.0f32; num_samples];
        decoded.copy_to_slice_interleaved(&mut interleaved);

        if interleaved.iter().any(|&s| !s.is_finite()) {
            debug!("流式: 解码帧含无效样本，跳过");
            continue;
        }

        let in_ch = spec.channels().count();
        let mixed = mix_channels(&interleaved, in_ch, out_ch);

        let pts = packet.pts.get() as f64 / src_rate as f64;
        last_pts = resample_and_send(
            &mixed,
            &mut rubato_resampler,
            &mut rubato_buf,
            out_ch,
            target_rate,
            target_ch,
            pts,
            &tx,
            &stop_rx,
        );

        // 渐进式时长估算：用「已消费字节 / 已解码秒数」得出真实平均码率，
        // 再反推总时长 = content_length / 平均码率。随解码推进，consumed→
        // content_length、last_pts→真实时长，估算自动收敛（CBR 很快、VBR 渐近）。
        // 对 FLAC/MP3/AAC 等压缩格式远优于固定公式；content_length 缺失
        // （如 chunked 无 Content-Length）时无法估算，跳过。
        if let Some(total) = content_length {
            if last_pts > 0.3 {
                let consumed = bytes_consumed.load(Ordering::Relaxed);
                if consumed > 0 {
                    let avg_bps = consumed as f64 / last_pts;
                    let est = total as f64 / avg_bps;
                    let now = Instant::now();
                    if est > 0.0
                        && (dur_est.is_none()
                            || now.duration_since(dur_est_sent) >= Duration::from_millis(300)
                            || (est - dur_est.unwrap()).abs() / est > 0.02)
                    {
                        let _ = event_tx.send(EngineEvent::DurationSecs(est));
                        dur_est = Some(est);
                        dur_est_sent = now;
                    }
                }
            }
        }
    }
    flush_resampler(
        &mut rubato_resampler,
        &mut rubato_buf,
        out_ch,
        target_rate,
        target_ch,
        last_pts,
        &tx,
        &stop_rx,
    );
    Ok(())
}

/// 将整个音频文件解码到内存，返回交错 PCM f32 样本。
/// 适用于小文件（如音效、短片段）或离线分析。
pub fn decode_to_memory(path: &Path, tr: u32, tc: u32) -> Result<Vec<f32>, String> {
    decode_to_memory_prefix(path, tr, tc, None)
}

/// 同 [decode_to_memory]，但只解码前 `max_secs` 秒（`None` = 全曲）。
/// BPM/调性等分析任务只需开头几十秒即可，避免全曲解码的 CPU 开销。
pub fn decode_to_memory_prefix(
    path: &Path,
    tr: u32,
    tc: u32,
    max_secs: Option<f64>,
) -> Result<Vec<f32>, String> {
    /// 最大解码样本数（~2GB @f32），防止超大文件 OOM
    const MAX_SAMPLES: usize = 512 * 1024 * 1024;
    let (rx, dec) = Decoder::start(path, tr, tc, Arc::new(AtomicU64::new(0)), None, max_secs)?;
    let mut all = Vec::new();
    while let Ok(f) = rx.recv_timeout(Duration::from_secs(10)) {
        all.extend(f.samples);
        if all.len() > MAX_SAMPLES {
            dec.stop();
            return Err(format!("文件过大，超过 {} 样本上限", MAX_SAMPLES));
        }
    }
    dec.stop();
    if all.is_empty() {
        Err("解码为空".into())
    } else {
        Ok(all)
    }
}

fn run_dsd(
    path: &Path,
    target_rate: u32,
    target_ch: u32,
    tx: Sender<DecodedFrame>,
    stop_rx: Receiver<()>,
    seek_pos: Option<f64>,
    end_secs: Option<f64>,
) -> Result<(), EngineError> {
    use dsd_reader::DsdReader;

    // 流式解码器：恒定内存占用
    let mut converter =
        dsd::StreamingDsdDecoder::new(path).map_err(|e| EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: format!("DSD 解码失败: {e}"),
        })?;
    let src_rate = converter.sample_rate();
    let src_ch = converter.channels();
    let out_ch = target_ch as usize;

    info!(
        "DSD 流式解码: {} ({}Hz, {}ch)",
        path.display(),
        src_rate,
        src_ch
    );

    // 创建 DSD 迭代器
    let reader =
        DsdReader::from_container(path.to_path_buf()).map_err(|e| EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: format!("DSD 文件打开失败: {e}"),
        })?;
    let iter = reader.dsd_iter().map_err(|e| EngineError::DecodeFailed {
        path: path.to_path_buf(),
        reason: format!("DSD 迭代器创建失败: {e}"),
    })?;

    // Seek：计算需要跳过的 DSD 字节数（每声道）
    // DSD bytes_per_sec_per_channel = src_rate * 8 (64x 降采样后得 src_rate PCM frames/s)
    let mut skip_bytes: usize = if let Some(secs) = seek_pos {
        (secs * src_rate as f64) as usize * 8
    } else {
        0
    };

    // end_secs 截止：跟踪已输出的 PCM 帧数
    let max_output_frames: Option<u64> = if let Some(end) = end_secs {
        let start = seek_pos.unwrap_or(0.0);
        let dur = end - start;
        if dur > 0.0 {
            Some((dur * src_rate as f64) as u64)
        } else {
            None
        }
    } else {
        None
    };
    let mut output_frames: u64 = 0;

    // 重采样器（如需要）
    let mut resampler = create_resampler(src_rate, target_rate, out_ch);
    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];
    let mut pts = 0.0f64;

    // 主循环：流式读取 DSD 块 → 转换 → 混音 → 重采样 → 发送
    for (_nread, chan_frames) in iter {
        if stop_rx.try_recv().is_ok() {
            return Ok(());
        }

        // Seek 跳过
        if skip_bytes > 0 {
            let block_len = chan_frames.first().map(|b| b.len()).unwrap_or(0);
            if block_len == 0 {
                continue;
            }
            if skip_bytes >= block_len {
                skip_bytes -= block_len;
                continue;
            } else {
                // 部分跳过：截断每个声道的前 N 字节
                let skip = skip_bytes;
                skip_bytes = 0;
                let truncated: Vec<Box<[u8]>> = chan_frames
                    .iter()
                    .map(|b| b[skip..].to_vec().into_boxed_slice())
                    .collect();
                converter.feed(&truncated);
            }
        } else {
            converter.feed(&chan_frames);
        }

        // 达到阈值时 flush 并发送
        // feed() 返回 bool 但我们每次都尝试 flush（小文件可能永远不达阈值）
        let pcm = converter.flush();
        if pcm.is_empty() {
            continue;
        }

        // 声道混音
        let mixed = mix_channels(&pcm, src_ch, out_ch);

        // end_secs 截断
        let mixed = if let Some(max_frames) = max_output_frames {
            let remaining = max_frames.saturating_sub(output_frames);
            let allowed_samples = remaining as usize * out_ch;
            if mixed.len() > allowed_samples {
                mixed[..allowed_samples].to_vec()
            } else {
                mixed
            }
        } else {
            mixed
        };
        if mixed.is_empty() {
            break;
        }

        // 重采样或直发
        pts = resample_and_send(
            &mixed,
            &mut resampler,
            &mut rubato_buf,
            out_ch,
            target_rate,
            target_ch,
            pts,
            &tx,
            &stop_rx,
        );

        output_frames += (mixed.len() / out_ch) as u64;
        if let Some(max_frames) = max_output_frames {
            if output_frames >= max_frames {
                break;
            }
        }
    }

    // 最终 flush：处理剩余数据
    let pcm = converter.finalize();
    if !pcm.is_empty() && stop_rx.try_recv().is_err() {
        let mixed = mix_channels(&pcm, src_ch, out_ch);
        if !mixed.is_empty() {
            pts = resample_and_send(
                &mixed,
                &mut resampler,
                &mut rubato_buf,
                out_ch,
                target_rate,
                target_ch,
                pts,
                &tx,
                &stop_rx,
            );
        }
    }
    flush_resampler(
        &mut resampler,
        &mut rubato_buf,
        out_ch,
        target_rate,
        target_ch,
        pts,
        &tx,
        &stop_rx,
    );
    Ok(())
}

/// APE (Monkey's Audio) 直解：纯 Rust ape-decoder，输出统一小端交错 PCM 字节。
/// 与 run_dsd 同构：逐帧解码 → 字节转 f32 → 混音 → 重采样 → 发送。
fn run_ape(
    path: &Path,
    target_rate: u32,
    target_ch: u32,
    tx: Sender<DecodedFrame>,
    stop_rx: Receiver<()>,
    seek_pos: Option<f64>,
    end_secs: Option<f64>,
) -> Result<(), EngineError> {
    use ape_decoder::ApeDecoder;

    let file = File::open(path).map_err(|_| EngineError::FileNotFound(path.to_path_buf()))?;
    let mut decoder = ApeDecoder::new(file).map_err(|e| EngineError::DecodeFailed {
        path: path.to_path_buf(),
        reason: format!("APE 打开失败: {e}"),
    })?;
    let info = decoder.info().clone();

    // 老版本 APE (< 3.95) 不支持
    if info.version < 3950 {
        return Err(EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: format!("APE 版本过旧 (v{})，需 3.95+", info.version),
        });
    }

    let src_rate = info.sample_rate;
    let src_ch = info.channels as usize;
    let bits = info.bits_per_sample as usize;
    let out_ch = target_ch as usize;
    let bytes_per_sample = bits.div_ceil(8);
    let is_float = info.is_floating_point;

    info!(
        "APE 直解: {} ({}Hz, {}ch, {}bit)",
        path.display(),
        src_rate,
        src_ch,
        bits
    );

    // Seek：定位到目标样本（APE 按样本 seek，天然精确）
    if let Some(secs) = seek_pos {
        let sample = (secs * src_rate as f64) as u64;
        let _ = decoder.seek(sample);
    }

    // end_secs 截止：跟踪已输出的 PCM 帧数（输出帧率 = src_rate，重采样前）
    let max_output_frames: Option<u64> = if let Some(end) = end_secs {
        let start = seek_pos.unwrap_or(0.0);
        let dur = end - start;
        if dur > 0.0 {
            Some((dur * src_rate as f64) as u64)
        } else {
            None
        }
    } else {
        None
    };
    let mut output_frames: u64 = 0;

    // 重采样器（如需要）
    let mut resampler = create_resampler(src_rate, target_rate, out_ch);
    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];
    let mut pts = 0.0f64;

    // 主循环：逐帧解码 → 字节转 f32 → 混音 → 重采样 → 发送
    for frame_result in decoder.frames() {
        if stop_rx.try_recv().is_ok() {
            return Ok(());
        }

        let raw = match frame_result {
            Ok(v) => v,
            Err(e) => {
                warn!("APE 帧解码失败: {e:?}");
                continue;
            }
        };
        if raw.is_empty() {
            continue;
        }

        // 字节 → 交错 f32（小端；8bit 无符号已 +128 偏置，float 已变换为 IEEE 位模式）
        let pcm = bytes_to_interleaved_f32(&raw, bytes_per_sample, is_float);

        // 声道混音
        let mixed = mix_channels(&pcm, src_ch, out_ch);

        // end_secs 截断
        let mixed = if let Some(max_frames) = max_output_frames {
            let remaining = max_frames.saturating_sub(output_frames);
            let allowed_samples = remaining as usize * out_ch;
            if mixed.len() > allowed_samples {
                mixed[..allowed_samples].to_vec()
            } else {
                mixed
            }
        } else {
            mixed
        };
        if mixed.is_empty() {
            break;
        }

        // 重采样或直发
        pts = resample_and_send(
            &mixed,
            &mut resampler,
            &mut rubato_buf,
            out_ch,
            target_rate,
            target_ch,
            pts,
            &tx,
            &stop_rx,
        );

        output_frames += (mixed.len() / out_ch) as u64;
        if let Some(max_frames) = max_output_frames {
            if output_frames >= max_frames {
                break;
            }
        }
    }

    flush_resampler(
        &mut resampler,
        &mut rubato_buf,
        out_ch,
        target_rate,
        target_ch,
        pts,
        &tx,
        &stop_rx,
    );
    Ok(())
}

/// 将 ape-decoder 输出的统一小端交错 PCM 字节转为 f32 交错样本。
fn bytes_to_interleaved_f32(raw: &[u8], bytes_per_sample: usize, is_float: bool) -> Vec<f32> {
    let n_samples = raw.len() / bytes_per_sample;
    let mut out = Vec::with_capacity(n_samples);
    let mut i = 0usize;
    for _ in 0..n_samples {
        let s = if is_float && bytes_per_sample == 4 {
            // 浮点 APE：位模式直接还原（输出已是 IEEE 754 小端）
            let bits = u32::from_le_bytes([raw[i], raw[i + 1], raw[i + 2], raw[i + 3]]);
            f32::from_bits(bits)
        } else {
            match bytes_per_sample {
                1 => (raw[i] as f32 - 128.0) / 128.0, // 无符号 8bit → [-1,1)
                2 => {
                    let v = i16::from_le_bytes([raw[i], raw[i + 1]]) as f32;
                    v / 32768.0
                }
                3 => {
                    // 24bit 有符号（小端），左移 8 位后算术右移实现符号扩展
                    let v = ((raw[i] as i32)
                        | ((raw[i + 1] as i32) << 8)
                        | ((raw[i + 2] as i32) << 16))
                        << 8
                        >> 8;
                    v as f32 / 8388608.0
                }
                _ => {
                    let v = i32::from_le_bytes([raw[i], raw[i + 1], raw[i + 2], raw[i + 3]]) as f32;
                    v / 2147483648.0
                }
            }
        };
        out.push(s);
        i += bytes_per_sample;
    }
    out
}

/// 将累积的 DSD 字节打包为 DoP 帧并发送（按偶数字节消费，奇数尾部保留）
#[allow(clippy::too_many_arguments)]
fn flush_pack_dop(
    chan_buf: &mut [Vec<u8>],
    packer: &mut crate::dsd::dop::DopPacker,
    packed: &mut Vec<f32>,
    tx: &Sender<DecodedFrame>,
    stop_rx: &Receiver<()>,
    out_ch: usize,
    pcm_rate: u32,
    pts: &mut f64,
    output_frames: &mut u64,
    max_output_frames: Option<u64>,
) {
    let usable = chan_buf.iter().map(|b| b.len() / 2 * 2).min().unwrap_or(0);
    if usable == 0 {
        return;
    }
    let refs: Vec<&[u8]> = chan_buf.iter().map(|b| &b[..usable]).collect();
    packed.clear();
    let frames = packer.pack(&refs, packed);
    for b in chan_buf.iter_mut() {
        b.drain(..(frames * 2).min(b.len()));
    }
    if packed.is_empty() {
        return;
    }
    // end_secs 截断
    let send_len = match max_output_frames {
        Some(max) => packed
            .len()
            .min(max.saturating_sub(*output_frames) as usize * out_ch),
        None => packed.len(),
    };
    if send_len == 0 {
        return;
    }
    let n_frames = send_len / out_ch;
    try_send_or_stop(
        tx,
        DecodedFrame {
            samples: packed[..send_len].to_vec(),
            pts_secs: *pts,
            sample_rate: pcm_rate,
            channels: out_ch as u32,
        },
        stop_rx,
    );
    *pts += n_frames as f64 / pcm_rate as f64;
    *output_frames += n_frames as u64;
}

/// DoP 直出：原始 DSD 比特 → DoP PCM 帧（不转 PCM、不重采样）
fn run_dsd_dop(
    path: &Path,
    left_justify: bool,
    target_ch: u32,
    tx: Sender<DecodedFrame>,
    stop_rx: Receiver<()>,
    seek_pos: Option<f64>,
    end_secs: Option<f64>,
) -> Result<(), EngineError> {
    use crate::dsd::dop::{dop_pcm_rate, dop_supported, DopPacker};
    use dsd_reader::DsdReader;

    let reader =
        DsdReader::from_container(path.to_path_buf()).map_err(|e| EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: format!("DSD 文件打开失败: {e}"),
        })?;
    let mult = reader.dsd_rate();
    let dsd_rate_hz = 2_822_400 * mult.max(1) as u32;
    let src_ch = reader.channels_num();
    if src_ch == 0 {
        return Err(EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: "DSD 文件无声道".into(),
        });
    }
    if !dop_supported(dsd_rate_hz) {
        return Err(EngineError::DecodeFailed {
            path: path.to_path_buf(),
            reason: format!(
                "DSD 速率 {}Hz 过高，无法 DoP 直出（上限 DSD256）",
                dsd_rate_hz
            ),
        });
    }
    let pcm_rate = dop_pcm_rate(dsd_rate_hz);
    let out_ch = if target_ch == 0 {
        src_ch
    } else {
        src_ch.min(target_ch as usize).max(1)
    };

    info!(
        "DoP 直出: {} (DSD{} → {}kHz PCM, {}ch)",
        path.display(),
        mult * 64,
        pcm_rate / 1000,
        out_ch
    );

    let iter = reader.dsd_iter().map_err(|e| EngineError::DecodeFailed {
        path: path.to_path_buf(),
        reason: format!("DSD 迭代器创建失败: {e}"),
    })?;

    // Seek：每声道需跳过的 DSD 字节数 = secs * dsd_rate / 8
    let mut skip_bytes: usize = if let Some(secs) = seek_pos {
        (secs * dsd_rate_hz as f64 / 8.0) as usize
    } else {
        0
    };
    let max_output_frames: Option<u64> = if let Some(end) = end_secs {
        let start = seek_pos.unwrap_or(0.0);
        let dur = end - start;
        if dur > 0.0 {
            Some((dur * pcm_rate as f64) as u64)
        } else {
            None
        }
    } else {
        None
    };

    let mut packer = DopPacker::new(left_justify);
    // 每声道累积缓冲（达阈后打包发送）
    const FLUSH_BYTES: usize = 8192;
    let mut chan_buf: Vec<Vec<u8>> = (0..src_ch)
        .map(|_| Vec::with_capacity(FLUSH_BYTES + 4096))
        .collect();
    let mut packed: Vec<f32> = Vec::with_capacity(FLUSH_BYTES / 2 * out_ch);
    let mut output_frames: u64 = 0;
    let mut pts = 0.0f64;

    for (_nread, chan_frames) in iter {
        if stop_rx.try_recv().is_ok() {
            return Ok(());
        }
        if let Some(max_frames) = max_output_frames {
            if output_frames >= max_frames {
                break;
            }
        }

        // Seek 跳过
        if skip_bytes > 0 {
            let block_len = chan_frames.first().map(|b| b.len()).unwrap_or(0);
            if block_len == 0 {
                continue;
            }
            if skip_bytes >= block_len {
                skip_bytes -= block_len;
                continue;
            } else {
                let skip = skip_bytes;
                skip_bytes = 0;
                for (c, data) in chan_frames.iter().enumerate() {
                    if let Some(buf) = chan_buf.get_mut(c) {
                        buf.extend_from_slice(&data[skip.min(data.len())..]);
                    }
                }
            }
        } else {
            for (c, data) in chan_frames.iter().enumerate() {
                if let Some(buf) = chan_buf.get_mut(c) {
                    buf.extend_from_slice(data);
                }
            }
        }

        if chan_buf
            .first()
            .map(|b| b.len() >= FLUSH_BYTES)
            .unwrap_or(false)
        {
            flush_pack_dop(
                &mut chan_buf,
                &mut packer,
                &mut packed,
                &tx,
                &stop_rx,
                out_ch,
                pcm_rate,
                &mut pts,
                &mut output_frames,
                max_output_frames,
            );
        }
    }

    // 文件结束：打包剩余字节
    if stop_rx.try_recv().is_err() {
        flush_pack_dop(
            &mut chan_buf,
            &mut packer,
            &mut packed,
            &tx,
            &stop_rx,
            out_ch,
            pcm_rate,
            &mut pts,
            &mut output_frames,
            max_output_frames,
        );
    }
    Ok(())
}

/// 声道混音：将交错 PCM 从 in_ch 混到 out_ch
///
/// 多声道 downmix 按 ITU-R BS.775 标准：
/// - 5.1 (FL FR FC LFE RL RR) → 2.0: L' = FL + 0.707*FC + 0.707*RL, R' = FR + 0.707*FC + 0.707*RR
/// - 7.1 (FL FR FC LFE RL RR SL SR) → 2.0: L' = FL + 0.707*FC + 0.5*RL + 0.707*SL
/// - 3.0+ (FL FR FC ...) → 2.0: L' = FL + 0.707*FC, R' = FR + 0.707*FC
/// - 单声道输出：所有声道等权平均
fn mix_channels(pcm: &[f32], in_ch: usize, out_ch: usize) -> Vec<f32> {
    if in_ch == out_ch {
        return pcm.to_vec();
    }
    let in_frames = pcm.len() / in_ch;
    let mut mixed = Vec::with_capacity(in_frames * out_ch);

    if out_ch == 1 {
        // 单声道：所有声道等权平均
        for f in 0..in_frames {
            let off = f * in_ch;
            mixed.push(pcm[off..off + in_ch].iter().sum::<f32>() / in_ch as f32);
        }
    } else if in_ch <= 2 {
        // 单声道→立体声 或 已经是立体声
        for f in 0..in_frames {
            let off = f * in_ch;
            let l = if in_ch >= 1 { pcm[off] } else { 0.0 };
            let r = if in_ch >= 2 { pcm[off + 1] } else { l };
            mixed.push(l);
            mixed.push(r);
        }
    } else {
        // 多声道 → 立体声 downmix (ITU-R BS.775)
        const C: f32 = 0.707; // 中置/环绕衰减 -3dB
        const S: f32 = 0.5; // 侧环绕衰减 -6dB (7.1)
        for f in 0..in_frames {
            let off = f * in_ch;
            let fl = pcm[off];
            let fr = if in_ch >= 2 { pcm[off + 1] } else { fl };
            let fc = if in_ch >= 3 { pcm[off + 2] } else { 0.0 };
            // ch[3] = LFE，丢弃
            let rl = if in_ch >= 5 { pcm[off + 4] } else { 0.0 };
            let rr = if in_ch >= 6 { pcm[off + 5] } else { 0.0 };
            let sl = if in_ch >= 7 { pcm[off + 6] } else { 0.0 };
            let sr = if in_ch >= 8 { pcm[off + 7] } else { 0.0 };

            let l = fl + C * fc + C * rl + S * sl;
            let r = fr + C * fc + C * rr + S * sr;
            mixed.push(l);
            mixed.push(r);
        }
    }
    mixed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TARGET_CHANNELS, TARGET_SAMPLE_RATE};

    fn test_decode(path: &str) -> Option<u64> {
        let p = std::path::Path::new(path);
        if !p.exists() {
            return None;
        }
        let (rx, _decoder) = match Decoder::start(
            p,
            TARGET_SAMPLE_RATE,
            TARGET_CHANNELS,
            Arc::new(AtomicU64::new(0)),
            None,
            None,
        ) {
            Ok(v) => v,
            Err(_) => return None,
        };
        let mut t = 0u64;
        while let Ok(f) = rx.recv_timeout(Duration::from_secs(5)) {
            t += f.samples.len() as u64;
        }
        Some(t)
    }

    fn ensure_test_tone(path: &str) {
        if std::path::Path::new(path).exists() {
            return;
        }
        use hound::SampleFormat::Int;
        use hound::WavSpec;
        let spec = WavSpec {
            channels: 2,
            sample_rate: 44100,
            bits_per_sample: 16,
            sample_format: Int,
        };
        let mut w = hound::WavWriter::create(path, spec).unwrap();
        let n = (44100.0 * 0.5) as u32;
        for i in 0..n * 2 {
            let t = i as f64 / 44100.0;
            let s = (t * 440.0 * 2.0 * std::f64::consts::PI).sin() * 0.5;
            w.write_sample((s * i16::MAX as f64) as i16).unwrap();
        }
        w.finalize().unwrap();
    }

    #[test]
    fn test_decode_generated_wav() {
        ensure_test_tone("/tmp/_test_decode.wav");
        let samples = test_decode("/tmp/_test_decode.wav").unwrap_or(0);
        assert!(samples > 100, "解码样本数过少: {samples}");
    }

    #[test]
    fn test_probe_duration_wav() {
        ensure_test_tone("/tmp/_test_decode.wav");
        let secs =
            crate::decoder::probe_duration_secs(std::path::Path::new("/tmp/_test_decode.wav"));
        assert!(secs.is_some(), "WAV 应能从头探测时长");
        let secs = secs.unwrap();
        assert!(
            (secs - 0.5).abs() < 0.05,
            "WAV 0.5s 测试音时长探测偏差过大: {secs}"
        );
    }

    #[test]
    fn test_probe_dsf_header() {
        // 构造最小 DSF 头（76 字节覆盖 fmt chunk）：采样率 2822400，样本数 2822400*2
        let mut buf = Vec::with_capacity(76);
        buf.extend_from_slice(b"DSD ");
        buf.extend_from_slice(&[0x1c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // chunk size (8B, 28)
        buf.extend_from_slice(&[0x00; 8]); // total file size (占位)
        buf.extend_from_slice(&[0x00; 8]); // metadata ptr (占位)
        buf.extend_from_slice(b"fmt ");
        buf.extend_from_slice(&[0x1c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // fmt size (8B, 28)
        buf.extend_from_slice(&[0x01, 0x00, 0x00, 0x00]); // format version (1)
        buf.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // format id (0 = raw)
        buf.extend_from_slice(&[0x02, 0x00, 0x00, 0x00]); // channel type (2 = stereo)
        buf.extend_from_slice(&[0x02, 0x00, 0x00, 0x00]); // channel num (2)
        buf.extend_from_slice(&[0x00, 0x11, 0x2b, 0x00]); // sampling freq 2822400 @56
        buf.extend_from_slice(&[0x40, 0x00, 0x00, 0x00]); // bits (64)
        buf.extend_from_slice(&[0x00, 0x22, 0x56, 0x00, 0x00, 0x00, 0x00, 0x00]); // sample count 2822400*2 @64
        buf.extend_from_slice(&[0x00, 0x10, 0x00, 0x00]); // block size (4096)
        let path = "/tmp/_test_probe.dsf";
        std::fs::write(path, &buf).unwrap();
        let secs = crate::decoder::probe_dsf_secs(std::path::Path::new(path)).unwrap();
        assert!((secs - 2.0).abs() < 1e-6, "DSF 头部时长解析错误: {secs}");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn test_decode_invalid_file() {
        let result = test_decode("/tmp/_nonexistent_file_xyz.wav");
        assert!(result.is_none(), "不存在的文件应返回 None");
    }

    #[test]
    fn test_decode_stop_early() {
        ensure_test_tone("/tmp/_test_stop.wav");
        let (rx, dec) = Decoder::start(
            std::path::Path::new("/tmp/_test_stop.wav"),
            TARGET_SAMPLE_RATE,
            TARGET_CHANNELS,
            Arc::new(AtomicU64::new(0)),
            None,
            None,
        )
        .unwrap();
        // 接收少量帧后立即停止
        let mut count = 0u64;
        while let Ok(f) = rx.recv_timeout(Duration::from_millis(200)) {
            count += f.samples.len() as u64;
            if count > 5000 {
                break;
            }
        }
        dec.stop(); // 应快速返回，不阻塞
        assert!(count > 0, "应收到至少一些样本");
    }

    #[test]
    fn test_decode_random_bytes_no_panic() {
        // 随机字节喂给解码器，断言不 panic
        use fastrand::Rng;
        let mut rng = Rng::with_seed(42);
        for i in 0..50 {
            let len = rng.usize(1..4096);
            let data: Vec<u8> = (0..len).map(|_| rng.u8(..)).collect();
            let path = format!("/tmp/_fuzz_{i}.bin");
            std::fs::write(&path, &data).ok();
            let _ = Decoder::start(
                std::path::Path::new(&path),
                TARGET_SAMPLE_RATE,
                TARGET_CHANNELS,
                Arc::new(AtomicU64::new(0)),
                None,
                None,
            );
            std::fs::remove_file(&path).ok();
        }
    }

    #[test]
    fn test_decode_seek() {
        ensure_test_tone("/tmp/_test_seek.wav");
        let (rx, _dec) = Decoder::start(
            std::path::Path::new("/tmp/_test_seek.wav"),
            TARGET_SAMPLE_RATE,
            TARGET_CHANNELS,
            Arc::new(AtomicU64::new(0)),
            Some(0.1),
            None,
        )
        .unwrap();
        let mut frames = Vec::new();
        while let Ok(f) = rx.recv_timeout(Duration::from_secs(3)) {
            frames.push(f);
        }
        assert!(!frames.is_empty(), "seek 后应有帧输出");
        // 第一帧的 pts 应该在 0.1s 附近（允许 ±0.03s 误差）
        if let Some(first) = frames.first() {
            let delta = (first.pts_secs - 0.1).abs();
            assert!(
                delta < 0.03,
                "seek 时间偏差过大: 期望 0.1s, 实际: {}",
                first.pts_secs
            );
        }
    }

    // ── APE (Monkey's Audio) 直解 ──

    #[test]
    fn test_decode_ape_multiframe() {
        // 需要真实 APE 样本（ape-decoder 官方 fixtures 之一），缺失则跳过
        if !std::path::Path::new("/tmp/_test_multiframe.ape").exists() {
            eprintln!("跳过：缺少 APE 测试样本");
            return;
        }
        let samples = test_decode("/tmp/_test_multiframe.ape").unwrap_or(0);
        assert!(samples > 100, "APE 解码样本数过少: {samples}");
    }

    #[test]
    fn test_decode_ape_seek() {
        if !std::path::Path::new("/tmp/_test_multiframe.ape").exists() {
            eprintln!("跳过：缺少 APE 测试样本");
            return;
        }
        let (rx, _dec) = Decoder::start(
            std::path::Path::new("/tmp/_test_multiframe.ape"),
            TARGET_SAMPLE_RATE,
            TARGET_CHANNELS,
            Arc::new(AtomicU64::new(0)),
            Some(0.1),
            None,
        )
        .unwrap();
        let mut frames = Vec::new();
        while let Ok(f) = rx.recv_timeout(Duration::from_secs(5)) {
            frames.push(f);
        }
        assert!(!frames.is_empty(), "APE seek 后应有帧输出");
    }

    #[test]
    fn test_bytes_to_interleaved_f32() {
        // 16bit 小端: -32768 → -1.0, 32767 → ~0.99997
        let raw = vec![0x00, 0x80, 0xFF, 0x7F];
        let out = bytes_to_interleaved_f32(&raw, 2, false);
        assert_eq!(out.len(), 2);
        assert!(
            (out[0] + 1.0).abs() < 1e-6,
            "16bit min 应映射到 -1.0: {}",
            out[0]
        );
        assert!(
            (out[1] - (32767.0 / 32768.0)).abs() < 1e-6,
            "16bit max 映射错误: {}",
            out[1]
        );

        // 8bit 无符号: 0 → -1.0, 255 → ~0.992
        let raw = vec![0x00, 0xFF];
        let out = bytes_to_interleaved_f32(&raw, 1, false);
        assert!((out[0] + 1.0).abs() < 1e-6);
        assert!((out[1] - (127.0 / 128.0)).abs() < 1e-6);

        // 24bit 小端符号扩展: 0x000000 → 0, 0x800000 → -1.0(满幅负)
        let raw = vec![0x00, 0x00, 0x00, 0x00, 0x00, 0x80];
        let out = bytes_to_interleaved_f32(&raw, 3, false);
        assert!((out[0]).abs() < 1e-6);
        assert!((out[1] + 1.0).abs() < 1e-6, "24bit -1 映射错误: {}", out[1]);
        // 0xFFFFFF = 补码 -1 LSB ≈ -1.19e-7
        let raw = vec![0xFF, 0xFF, 0xFF];
        let out = bytes_to_interleaved_f32(&raw, 3, false);
        assert!(
            (out[0] + 1.0 / 8388608.0).abs() < 1e-6,
            "24bit 补码 -1 映射错误: {}",
            out[0]
        );

        // 32bit float: 1.0 的 IEEE 位模式
        let raw = 1.0f32.to_le_bytes().to_vec();
        let out = bytes_to_interleaved_f32(&raw, 4, true);
        assert!((out[0] - 1.0).abs() < 1e-6);
    }
}
