//! 解码器（Symphonia 流式解码 + DSD 文件直解）

use std::fs::File;

use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, bounded, unbounded, SendTimeoutError};
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::codecs::registry::RegisterableAudioDecoder;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use tracing::{debug, error, info, warn};

use rubato::{InterpolationParameters, InterpolationType, Resampler, SincFixedOut, WindowFunction};

use crate::error::EngineError;
use crate::dsd;
use lofty::prelude::*;
use lofty::read_from_path;

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
        path: &Path, target_rate: u32, target_channels: u32,
        position: Arc<AtomicU64>, seek_pos: Option<f64>,
        end_secs: Option<f64>,
    ) -> Result<(Receiver<DecodedFrame>, Self), EngineError> {
        let (tx, rx) = bounded(DECODE_CHANNEL_CAPACITY);
        let (stx, srx) = unbounded();
        let (err_tx, err_rx) = bounded::<EngineError>(1);
        let p = path.to_path_buf();
        let pos_clone = position.clone();
        let handle = thread::spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run(&p, target_rate, target_channels, tx, srx, position, seek_pos, end_secs)
            }));
            match result {
                Ok(Err(e)) => {
                    error!("解码失败: {e}");
                    let _ = err_tx.send(e);
                }
                Err(panic_info) => {
                    let msg = if let Some(s) = panic_info.downcast_ref::<&str>() { s.to_string() }
                              else if let Some(s) = panic_info.downcast_ref::<String>() { s.clone() }
                              else { "解码线程未知 panic".to_string() };
                    error!("解码线程 crash: {msg}");
                    let _ = err_tx.send(EngineError::DecodeFailed { path: p.clone(), reason: msg });
                }
                Ok(Ok(())) => {}
            }
        });
        Ok((rx, Decoder { tx: Some(stx), handle: Some(handle), position: pos_clone, err_rx: Some(err_rx) }))
    }
    /// 停止后台解码线程
    pub fn stop(&self) { if let Some(ref t) = self.tx { let _ = t.send(()); } }

    /// 从流式数据源启动解码（网络流媒体用）。
    ///
    /// - `source` — 平台层写入字节流的 `StreamMediaSource`
    /// - `target_rate` / `target_channels` — 输出重采样目标
    /// - `position` — 外部可读的解码进度
    /// - `format_hint` — 可选格式提示（如 "mp3", "flac", "aac"），帮助 Symphonia 探测
    pub fn start_from_stream(
        source: crate::stream::StreamMediaSource,
        target_rate: u32, target_channels: u32,
        position: Arc<AtomicU64>,
        format_hint: Option<String>,
    ) -> Result<(Receiver<DecodedFrame>, Self), EngineError> {
        let (tx, rx) = bounded(DECODE_CHANNEL_CAPACITY);
        let (stx, srx) = unbounded();
        let (err_tx, err_rx) = bounded::<EngineError>(1);
        let pos_clone = position.clone();
        let handle = thread::spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run_from_stream(source, target_rate, target_channels, tx, srx, position, format_hint)
            }));
            match result {
                Ok(Err(e)) => {
                    error!("流式解码失败: {e}");
                    let _ = err_tx.send(e);
                }
                Err(panic_info) => {
                    let msg = if let Some(s) = panic_info.downcast_ref::<&str>() { s.to_string() }
                              else if let Some(s) = panic_info.downcast_ref::<String>() { s.clone() }
                              else { "流式解码线程未知 panic".to_string() };
                    error!("流式解码线程 crash: {msg}");
                    let _ = err_tx.send(EngineError::DecodeFailed { path: "stream".into(), reason: msg });
                }
                Ok(Ok(())) => {}
            }
        });
        Ok((rx, Decoder { tx: Some(stx), handle: Some(handle), position: pos_clone, err_rx: Some(err_rx) }))
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
                if !stop_rx.is_empty() { return; }
            }
            Err(SendTimeoutError::Disconnected(_)) => return,
        }
    }
}

/// 创建 rubato 重采样器（如源/目标采样率不同）
fn create_resampler(src_rate: u32, target_rate: u32, out_ch: usize) -> Option<SincFixedOut<f64>> {
    if (src_rate as i64 - target_rate as i64).abs() <= 1 { return None; }
    let params = InterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: InterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };
    Some(SincFixedOut::<f64>::new(
        target_rate as f64 / src_rate as f64, params, 1024, out_ch,
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
            if rubato_buf[0].len() < needed { break; }
            let waves_in: Vec<Vec<f64>> = rubato_buf.iter_mut()
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
                    try_send_or_stop(tx, DecodedFrame {
                        samples, pts_secs: cur_pts,
                        sample_rate: target_rate, channels: target_ch,
                    }, stop_rx);
                    cur_pts += out_frames as f64 / target_rate as f64;
                }
                Err(e) => warn!("rubato 重采样失败: {e:?}"),
            }
        }
        cur_pts
    } else {
        try_send_or_stop(tx, DecodedFrame {
            samples: mixed.to_vec(), pts_secs: pts,
            sample_rate: target_rate, channels: target_ch,
        }, stop_rx);
        pts + (mixed.len() / out_ch) as f64 / target_rate as f64
    }
}

fn run(
    path: &Path, target_rate: u32, target_ch: u32,
    tx: Sender<DecodedFrame>, stop_rx: Receiver<()>,
    _position: Arc<AtomicU64>, seek_pos: Option<f64>,
    end_secs: Option<f64>,
) -> Result<(), EngineError> {
    // 绕过 Symphonia 直解：DSD
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        if ext.eq_ignore_ascii_case("dsf") || ext.eq_ignore_ascii_case("dff") {
            return run_dsd(path, target_rate, target_ch, tx, stop_rx, seek_pos, end_secs);
        }
    }

    let file = File::open(path)
        .map_err(|_| EngineError::FileNotFound(path.to_path_buf()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe().probe(
        &hint, mss, FormatOptions::default(), MetadataOptions::default(),
    ).map_err(|e| EngineError::DecodeFailed { path: path.to_path_buf(), reason: format!("探测失败: {e}") })?;
    let (track_id, audio_cp) = {
        let track = format.default_track(TrackType::Audio)
            .ok_or_else(|| EngineError::DecodeFailed { path: path.to_path_buf(), reason: "无音频轨".into() })?;
        let cp = match &track.codec_params {
            Some(symphonia::core::codecs::CodecParameters::Audio(a)) => a.clone(),
            _ => return Err(EngineError::DecodeFailed { path: path.to_path_buf(), reason: "非音频编解码参数".into() }),
        };
        (track.id, cp)
    };
    let src_rate = audio_cp.sample_rate.unwrap_or(44100);
    let src_ch = audio_cp.channels.as_ref().map(|c| c.count()).unwrap_or(2) as u32;
    info!("解码: {} ({}Hz, {}ch)", path.display(), src_rate, src_ch);

    // 先尝试默认 codecs，失败则降级到 Opus 适配器
    let mut decoder = match symphonia::default::get_codecs().make_audio_decoder(&audio_cp, &AudioDecoderOptions::default()) {
        Ok(d) => d,
        Err(_) => match symphonia_adapter_oporus::OpusDecoder::try_registry_new(&audio_cp, &AudioDecoderOptions::default()) {
            Ok(d) => { info!("使用 Opus 适配器解码"); d }
            Err(e) => return Err(EngineError::DecodeFailed { path: path.to_path_buf(), reason: format!("创建解码器失败: {e}") }),
        }
    };

    // 跳转到指定时间位置
    if let Some(secs) = seek_pos {
        // 先用 format.seek() 尝试精确跳转
        let seek_time = symphonia::core::units::Time::try_from_secs_f64(secs).unwrap_or(symphonia::core::units::Time::ZERO);
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
        let new_dec = symphonia::default::get_codecs().make_audio_decoder(&audio_cp, &AudioDecoderOptions::default())
            .or_else(|_| symphonia_adapter_oporus::OpusDecoder::try_registry_new(&audio_cp, &AudioDecoderOptions::default()));
        match new_dec {
            Ok(d) => decoder = d,
            Err(e) => return Err(EngineError::DecodeFailed { path: path.to_path_buf(), reason: format!("seek 后解码器重建失败: {e}") }),
        }
    }

    // ── 创建 rubato 重采样器（如有必要） ──
    let out_ch = target_ch as usize;
    let mut rubato_resampler = create_resampler(src_rate, target_rate, out_ch);
    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];

    loop {
        if stop_rx.try_recv().is_ok() { break; }
        let packet = match format.next_packet() {
            Ok(Some(pkt)) => pkt,
            Ok(None) => { debug!("EOF"); break; }
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof => { debug!("EOF"); break; }
            Err(e) => { debug!("结束: {e}"); break; }
        };
        if packet.track_id != track_id { continue; }

        // end_secs 分段截断
        if let Some(end) = end_secs {
            if (packet.pts.get() as f64 / src_rate as f64) >= end {
                debug!("到达 end_secs={end}, 停止解码");
                break;
            }
        }

        let decoded = match decoder.decode(&packet) {
            Ok(buf) => buf,
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
            Err(e) => { debug!("解码错误: {e}"); continue; }
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
        let _ = resample_and_send(&mixed, &mut rubato_resampler, &mut rubato_buf,
            out_ch, target_rate, target_ch, pts, &tx, &stop_rx);
    }
    Ok(())
}

/// 流式解码：从 `StreamMediaSource` 读取字节流 → Symphonia 解码 → 重采样 → 发送
fn run_from_stream(
    source: crate::stream::StreamMediaSource,
    target_rate: u32, target_ch: u32,
    tx: Sender<DecodedFrame>, stop_rx: Receiver<()>,
    _position: Arc<AtomicU64>,
    format_hint: Option<String>,
) -> Result<(), EngineError> {
    let mss = MediaSourceStream::new(Box::new(source), Default::default());
    let mut hint = Hint::new();
    if let Some(ref ext) = format_hint {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe().probe(
        &hint, mss, FormatOptions::default(), MetadataOptions::default(),
    ).map_err(|e| EngineError::DecodeFailed { path: "stream".into(), reason: format!("流式探测失败: {e}") })?;
    let (track_id, audio_cp) = {
        let track = format.default_track(TrackType::Audio)
            .ok_or_else(|| EngineError::DecodeFailed { path: "stream".into(), reason: "无音频轨".into() })?;
        let cp = match &track.codec_params {
            Some(symphonia::core::codecs::CodecParameters::Audio(a)) => a.clone(),
            _ => return Err(EngineError::DecodeFailed { path: "stream".into(), reason: "非音频编解码参数".into() }),
        };
        (track.id, cp)
    };
    let src_rate = audio_cp.sample_rate.unwrap_or(44100);
    let out_ch = target_ch as usize;
    info!("流式解码: {}Hz, hint={:?}", src_rate, format_hint);

    let mut decoder = match symphonia::default::get_codecs().make_audio_decoder(&audio_cp, &AudioDecoderOptions::default()) {
        Ok(d) => d,
        Err(_) => match symphonia_adapter_oporus::OpusDecoder::try_registry_new(&audio_cp, &AudioDecoderOptions::default()) {
            Ok(d) => { info!("流式: 使用 Opus 适配器解码"); d }
            Err(e) => return Err(EngineError::DecodeFailed { path: "stream".into(), reason: format!("创建解码器失败: {e}") }),
        }
    };

    let mut rubato_resampler = create_resampler(src_rate, target_rate, out_ch);
    let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];

    loop {
        if stop_rx.try_recv().is_ok() { break; }
        let packet = match format.next_packet() {
            Ok(Some(pkt)) => pkt,
            Ok(None) => { debug!("流式 EOF"); break; }
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof => { debug!("流式 EOF"); break; }
            Err(e) => { debug!("流式结束: {e}"); break; }
        };
        if packet.track_id != track_id { continue; }

        let decoded = match decoder.decode(&packet) {
            Ok(buf) => buf,
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
            Err(e) => { debug!("流式解码错误: {e}"); continue; }
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
        let _ = resample_and_send(&mixed, &mut rubato_resampler, &mut rubato_buf,
            out_ch, target_rate, target_ch, pts, &tx, &stop_rx);
    }
    Ok(())
}

/// 将整个音频文件解码到内存，返回交错 PCM f32 样本。
/// 适用于小文件（如音效、短片段）或离线分析。
pub fn decode_to_memory(path: &Path, tr: u32, tc: u32) -> Result<Vec<f32>, String> {
    /// 最大解码样本数（~2GB @f32），防止超大文件 OOM
    const MAX_SAMPLES: usize = 512 * 1024 * 1024;
    let (rx, dec) = Decoder::start(path, tr, tc, Arc::new(AtomicU64::new(0)), None, None)?;
    let mut all = Vec::new();
    while let Ok(f) = rx.recv_timeout(Duration::from_secs(10)) {
        all.extend(f.samples);
        if all.len() > MAX_SAMPLES {
            dec.stop();
            return Err(format!("文件过大，超过 {} 样本上限", MAX_SAMPLES));
        }
    }
    dec.stop();
    if all.is_empty() { Err("解码为空".into()) } else { Ok(all) }
}

/// 音频文件元数据
pub struct Metadata {
    /// 曲名
    pub title: Option<String>,
    /// 艺术家
    pub artist: Option<String>,
    /// 专辑名
    pub album: Option<String>,
    /// 流派
    pub genre: Option<String>,
    /// 发行年份
    pub year: Option<i32>,
    /// 音轨号
    pub track_number: Option<u32>,
    /// 光盘号
    pub disc_number: Option<u32>,
    /// 时长（秒）
    pub duration_secs: f64,
    /// 是否含有内嵌封面
    pub has_cover: bool,
    /// 采样率（Hz）
    pub sample_rate: Option<u32>,
    /// 声道数
    pub channels: Option<u32>,
}

/// 读取音频文件元数据（标题/艺术家/专辑/流派/年份/音轨号/光盘号/封面/时长）
pub fn read_metadata(path: &Path) -> Result<Metadata, String> {
    // 优先用 lofty 读取完整标签
    if let Ok(tagged_file) = read_from_path(path) {
        let duration_secs = tagged_file.properties().duration().as_secs_f64();

        let mut meta = Metadata {
            title: None, artist: None, album: None,
            genre: None, year: None,
            track_number: None, disc_number: None,
            duration_secs, has_cover: false,
            sample_rate: None, channels: None,
        };

        if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
            meta.title = tag.title().map(|s| s.to_string());
            meta.artist = tag.artist().map(|s| s.to_string());
            meta.album = tag.album().map(|s| s.to_string());
            meta.genre = tag.genre().map(|s| s.to_string());
            meta.year = tag.date().map(|d| d.year as i32);
            meta.track_number = tag.track();
            meta.disc_number = tag.disk();
            meta.has_cover = !tag.pictures().is_empty();
        }

        meta.sample_rate = tagged_file.properties().sample_rate();
        meta.channels = tagged_file.properties().channels().map(|c| c as u32);

        return Ok(meta);
    }

    // lofty 不支持的格式（DSF/DFF/WavPack）回退到 Symphonia 探测时长
    let duration_secs = probe_duration_secs(path).unwrap_or(0.0);

    Ok(Metadata {
        title: None, artist: None, album: None,
        genre: None, year: None,
        track_number: None, disc_number: None,
        duration_secs, has_cover: false,
        sample_rate: None, channels: None,
    })
}

/// 用 Symphonia 探测音频时长（秒），不完整解码
pub(crate) fn probe_duration_secs(path: &Path) -> Option<f64> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .ok()?;
    format.tracks().iter()
        .find(|t| matches!(&t.codec_params, Some(symphonia::core::codecs::CodecParameters::Audio(p))
            if p.codec != symphonia::core::codecs::audio::CODEC_ID_NULL_AUDIO))
        .and_then(|t| {
            let frames = t.num_frames?;
            let tb = t.time_base?;
            let secs = frames as f64 * tb.numer.get() as f64 / tb.denom.get() as f64;
            if secs > 0.0 { Some(secs) } else { None }
        })
}

/// 读取音频文件内嵌封面图（JPEG/PNG 原始字节）
/// 读取封面图片（JPEG/PNG/WEBP 原始字节）。
/// 支持音频格式（lofty）以及 MKV/WebM 附件封面。
pub fn read_cover(path: &Path) -> Result<Vec<u8>, String> {
    // 先用 lofty 读音频 + MP4 封面
    if let Ok(tagged_file) = read_from_path(path) {
        if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
            if let Some(pic) = tag.pictures().first() {
                let data = pic.data();
                if !data.is_empty() {
                    return Ok(data.to_vec());
                }
            }
        }
    }

    // MKV/WebM 回退：从附件中找封面
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        if ext.eq_ignore_ascii_case("mkv") || ext.eq_ignore_ascii_case("webm") || ext.eq_ignore_ascii_case("mka") {
            if let Ok(mkv) = matroska::open(path) {
                for att in &mkv.attachments {
                    let name = att.name.to_lowercase();
                    if (name.starts_with("cover") || name.contains("cover"))
                        && !att.data.is_empty()
                            && (att.mime_type == "image/jpeg"
                                || att.mime_type == "image/png"
                                || att.mime_type == "image/webp")
                        {
                            return Ok(att.data.clone());
                        }
                }
                // 没有命名规范匹配的，按魔数返回第一个图片附件
                for att in &mkv.attachments {
                    let d = &att.data;
                    if d.len() >= 4
                        && ((d[0] == 0xFF && d[1] == 0xD8)      // JPEG
                            || d[0..4] == [0x89, 0x50, 0x4E, 0x47] // PNG
                            || (d.len() >= 12 && d[0..4] == [0x52, 0x49, 0x46, 0x46] && d[8..12] == [0x57, 0x45, 0x42, 0x50])) // RIFF+WEBP
                    {
                        return Ok(d.clone());
                    }
                }
            }
        }
    }

    Err("未找到封面".into())
}

/// ReplayGain 响度归一化增益值
#[derive(serde::Serialize)]
pub struct ReplayGain {
    /// 音轨增益 (dB)，如 -5.23
    pub track_gain_db: Option<f32>,
    /// 专辑增益 (dB)，如 -7.14
    pub album_gain_db: Option<f32>,
    /// 音轨真峰值，如 0.999969
    pub track_peak: Option<f32>,
    /// 专辑真峰值
    pub album_peak: Option<f32>,
}

/// 从音频文件读取 ReplayGain 标签（REPLAYGAIN_TRACK/ALBUM_GAIN/PEAK）
pub fn read_replaygain(path: &Path) -> Result<ReplayGain, String> {
    let tagged_file = read_from_path(path)
        .map_err(|e| format!("无法读取 ReplayGain: {e}"))?;

    let mut rg = ReplayGain { track_gain_db: None, album_gain_db: None, track_peak: None, album_peak: None };

    if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
        // 从 ItemKey 获取 ReplayGain 值（lofty 自动映射 ID3v2 TXXX / Vorbis / MP4）
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainTrackGain) {
            rg.track_gain_db = parse_replaygain_str(val);
        }
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumGain) {
            rg.album_gain_db = parse_replaygain_str(val);
        }
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainTrackPeak) {
            rg.track_peak = val.trim().parse::<f32>().ok();
        }
        if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumPeak) {
            rg.album_peak = val.trim().parse::<f32>().ok();
        }
    }

    Ok(rg)
}

/// 解析 "-5.23 dB" 格式的 ReplayGain 增益字符串
fn parse_replaygain_str(s: &str) -> Option<f32> {
    let s = s.trim();
    // 去掉 " dB" 后缀
    let num = if let Some(stripped) = s.strip_suffix(" dB").or_else(|| s.strip_suffix("db")) {
        stripped
    } else {
        s
    };
    num.parse::<f32>().ok()
}

/// 快速探测音频文件的采样率（不完整解码，只读文件头）
pub fn probe_sample_rate(path: &Path) -> Option<u32> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .ok()?;
    for track in format.tracks() {
        if let Some(symphonia::core::codecs::CodecParameters::Audio(audio)) = &track.codec_params {
            let rate = audio.sample_rate.unwrap_or(44100);
            if rate > 0 { return Some(rate); }
        }
    }
    None
}

/// 快速探测音频文件的位深（不完整解码，只读文件头）
pub fn probe_bit_depth(path: &Path) -> Option<u16> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .ok()?;
    for track in format.tracks() {
        if let Some(symphonia::core::codecs::CodecParameters::Audio(audio)) = &track.codec_params {
            let bits = audio.bits_per_sample.unwrap_or(16);
            if bits > 0 { return Some(bits as u16); }
        }
    }
    None
}

// ── DSD 解码 ──────────────────────────────────────────────────────────

fn run_dsd(
    path: &Path, target_rate: u32, target_ch: u32,
    tx: Sender<DecodedFrame>, stop_rx: Receiver<()>,
    seek_pos: Option<f64>,
    end_secs: Option<f64>,
) -> Result<(), EngineError> {
    use dsd_reader::DsdReader;

    // 流式解码器：恒定内存占用
    let mut converter = dsd::StreamingDsdDecoder::new(path)
        .map_err(|e| EngineError::DecodeFailed { path: path.to_path_buf(), reason: format!("DSD 解码失败: {e}") })?;
    let src_rate = converter.sample_rate();
    let src_ch = converter.channels();
    let out_ch = target_ch as usize;

    info!("DSD 流式解码: {} ({}Hz, {}ch)", path.display(), src_rate, src_ch);

    // 创建 DSD 迭代器
    let reader = DsdReader::from_container(path.to_path_buf())
        .map_err(|e| EngineError::DecodeFailed { path: path.to_path_buf(), reason: format!("DSD 文件打开失败: {e}") })?;
    let iter = reader.dsd_iter()
        .map_err(|e| EngineError::DecodeFailed { path: path.to_path_buf(), reason: format!("DSD 迭代器创建失败: {e}") })?;

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
        if dur > 0.0 { Some((dur * src_rate as f64) as u64) } else { None }
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
        if stop_rx.try_recv().is_ok() { return Ok(()); }

        // Seek 跳过
        if skip_bytes > 0 {
            let block_len = chan_frames.first().map(|b| b.len()).unwrap_or(0);
            if block_len == 0 { continue; }
            if skip_bytes >= block_len {
                skip_bytes -= block_len;
                continue;
            } else {
                // 部分跳过：截断每个声道的前 N 字节
                let skip = skip_bytes;
                skip_bytes = 0;
                let truncated: Vec<Box<[u8]>> = chan_frames.iter()
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
        if pcm.is_empty() { continue; }

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
        if mixed.is_empty() { break; }

        // 重采样或直发
        pts = resample_and_send(&mixed, &mut resampler, &mut rubato_buf,
            out_ch, target_rate, target_ch, pts, &tx, &stop_rx);

        output_frames += (mixed.len() / out_ch) as u64;
        if let Some(max_frames) = max_output_frames {
            if output_frames >= max_frames { break; }
        }
    }

    // 最终 flush：处理剩余数据
    let pcm = converter.finalize();
    if !pcm.is_empty() && stop_rx.try_recv().is_err() {
        let mixed = mix_channels(&pcm, src_ch, out_ch);
        if !mixed.is_empty() {
            let _ = resample_and_send(&mixed, &mut resampler, &mut rubato_buf,
                out_ch, target_rate, target_ch, pts, &tx, &stop_rx);
        }
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
    if in_ch == out_ch { return pcm.to_vec(); }
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
        const S: f32 = 0.5;   // 侧环绕衰减 -6dB (7.1)
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
        if !p.exists() { return None; }
        let (rx, _decoder) = match Decoder::start(p, TARGET_SAMPLE_RATE, TARGET_CHANNELS, Arc::new(AtomicU64::new(0)), None, None) {
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
        if std::path::Path::new(path).exists() { return; }
        use hound::WavSpec;
        use hound::SampleFormat::Int;
        let spec = WavSpec { channels: 2, sample_rate: 44100, bits_per_sample: 16, sample_format: Int };
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
    fn test_decode_invalid_file() {
        let result = test_decode("/tmp/_nonexistent_file_xyz.wav");
        assert!(result.is_none(), "不存在的文件应返回 None");
    }

    #[test]
    fn test_decode_stop_early() {
        ensure_test_tone("/tmp/_test_stop.wav");
        let (rx, dec) = Decoder::start(
            std::path::Path::new("/tmp/_test_stop.wav"),
            TARGET_SAMPLE_RATE, TARGET_CHANNELS,
            Arc::new(AtomicU64::new(0)), None, None,
        ).unwrap();
        // 接收少量帧后立即停止
        let mut count = 0u64;
        while let Ok(f) = rx.recv_timeout(Duration::from_millis(200)) {
            count += f.samples.len() as u64;
            if count > 5000 { break; }
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
                TARGET_SAMPLE_RATE, TARGET_CHANNELS,
                Arc::new(AtomicU64::new(0)), None, None,
            );
            std::fs::remove_file(&path).ok();
        }
    }

    #[test]
    fn test_decode_seek() {
        ensure_test_tone("/tmp/_test_seek.wav");
        let (rx, _dec) = Decoder::start(
            std::path::Path::new("/tmp/_test_seek.wav"),
            TARGET_SAMPLE_RATE, TARGET_CHANNELS,
            Arc::new(AtomicU64::new(0)), Some(0.1), None,
        ).unwrap();
        let mut frames = Vec::new();
        while let Ok(f) = rx.recv_timeout(Duration::from_secs(3)) {
            frames.push(f);
        }
        assert!(!frames.is_empty(), "seek 后应有帧输出");
        // 第一帧的 pts 应该在 0.1s 附近（允许 ±0.03s 误差）
        if let Some(first) = frames.first() {
            let delta = (first.pts_secs - 0.1).abs();
            assert!(delta < 0.03, "seek 时间偏差过大: 期望 0.1s, 实际: {}", first.pts_secs);
        }
    }
}
