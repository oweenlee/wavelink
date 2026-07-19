//! 解码器（Symphonia 流式解码 + DSD 文件直解）

use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, bounded, unbounded, TrySendError};
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::codecs::registry::RegisterableAudioDecoder;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, RawValue, StandardTag};
use tracing::{debug, info, warn};

use rubato::{InterpolationParameters, InterpolationType, Resampler, SincFixedOut, WindowFunction};

use crate::dsd;

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
/// 用法：`Decoder::start(path, sr, ch, pos, seek) → (rx, handle)`
pub struct Decoder {
    tx: Option<Sender<()>>,
    handle: Option<JoinHandle<()>>,
    /// 解码进度（已输出样本数），可被外部读取
    pub position: Arc<AtomicU64>,
}

impl Drop for Decoder {
    fn drop(&mut self) {
        self.stop();
        if let Some(h) = self.handle.take() { let _ = h.join(); }
    }
}

impl Decoder {
    /// 启动后台解码线程。返回 (帧接收器, 解码器句柄)。
    /// - `path` — 音频文件路径
    /// - `target_rate` / `target_channels` — 输出重采样目标
    /// - `position` — 外部可读的解码进度（样本数）
    /// - `seek_pos` — 可选起始位置（秒）
    pub fn start(
        path: &Path, target_rate: u32, target_channels: u32,
        position: Arc<AtomicU64>, seek_pos: Option<f64>,
    ) -> Result<(Receiver<DecodedFrame>, Self), String> {
        let (tx, rx) = bounded(8);
        let (stx, srx) = unbounded();
        let p = path.to_path_buf();
        let pos_clone = position.clone();
        let handle = thread::spawn(move || run(&p, target_rate, target_channels, tx, srx, position, seek_pos));
        Ok((rx, Decoder { tx: Some(stx), handle: Some(handle), position: pos_clone }))
    }
    /// 停止后台解码线程
    pub fn stop(&self) { if let Some(ref t) = self.tx { let _ = t.send(()); } }
}

/// 有界 channel 发送：如果 channel 满则轮询 stop 信号，避免死锁
fn try_send_or_stop(tx: &Sender<DecodedFrame>, frame: DecodedFrame, stop_rx: &Receiver<()>) {
    let mut frame = frame;
    loop {
        match tx.try_send(frame) {
            Ok(()) => return,
            Err(TrySendError::Full(f)) => {
                frame = f;
                if stop_rx.len() > 0 { return; }
                thread::sleep(Duration::from_millis(1));
            }
            Err(TrySendError::Disconnected(_)) => return,
        }
    }
}

fn run(
    path: &Path, target_rate: u32, target_ch: u32,
    tx: Sender<DecodedFrame>, stop_rx: Receiver<()>,
    _position: Arc<AtomicU64>, seek_pos: Option<f64>,
) {
    // 绕过 Symphonia 直解：DSD / WavPack
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        if ext.eq_ignore_ascii_case("dsf") || ext.eq_ignore_ascii_case("dff") {
            return run_dsd(path, target_rate, target_ch, tx, stop_rx, seek_pos);
        }
        if ext.eq_ignore_ascii_case("wv") {
            return run_wavpack(path, target_rate, target_ch, tx, stop_rx, seek_pos);
        }
    }

    let file = match File::open(path) {
        Ok(f) => f, Err(e) => { warn!("打开失败: {e}"); return; }
    };
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let mut format = match symphonia::default::get_probe().probe(
        &hint, mss, FormatOptions::default(), MetadataOptions::default(),
    ) { Ok(p) => p, Err(e) => { warn!("探测失败: {e}"); return; } };
    let (track_id, audio_cp) = {
        let track = match format.default_track(TrackType::Audio) {
            Some(t) => t, None => { warn!("无音频轨"); return; }
        };
        let cp = match &track.codec_params {
            Some(symphonia::core::codecs::CodecParameters::Audio(a)) => a.clone(),
            _ => { warn!("非音频编解码参数"); return; }
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
            Err(e) => { warn!("创建解码器失败: {e}"); return; }
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
        // 解码器状态在 seek 后需要重置
        let new_dec = symphonia::default::get_codecs().make_audio_decoder(&audio_cp, &AudioDecoderOptions::default())
            .or_else(|_| symphonia_adapter_oporus::OpusDecoder::try_registry_new(&audio_cp, &AudioDecoderOptions::default()));
        if let Ok(d) = new_dec { decoder = d; }
    }

    // ── 创建 rubato 重采样器（如有必要） ──
    let need_resample = (src_rate as i64 - target_rate as i64).abs() > 1;
    let mut rubato_resampler: Option<SincFixedOut<f64>> = None;
    let mut rubato_buf: Vec<Vec<f64>> = Vec::new(); // 声道级输入缓冲
    if need_resample {
        let params = InterpolationParameters {
            sinc_len: 256,
            f_cutoff: 0.95,
            interpolation: InterpolationType::Linear,
            oversampling_factor: 256,
            window: WindowFunction::BlackmanHarris2,
        };
        let r = SincFixedOut::<f64>::new(
            target_rate as f64 / src_rate as f64,
            params, 1024, target_ch as usize,
        );
        rubato_buf = vec![Vec::new(); target_ch as usize];
        rubato_resampler = Some(r);
    }

    let out_ch = target_ch as usize;

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

        // 声道混音
        let in_frames = interleaved.len() / in_ch;
        let mut mixed = Vec::with_capacity(in_frames * out_ch);
        for f in 0..in_frames {
            let off = f * in_ch;
            if out_ch == 1 {
                mixed.push(interleaved[off..off + in_ch].iter().sum::<f32>() / in_ch as f32);
            } else {
                let l = if in_ch >= 1 { interleaved[off] } else { 0.0 };
                let r = if in_ch >= 2 { interleaved[off + 1] } else { l };
                mixed.push(l); mixed.push(r);
            }
        }

        // rubato 异步 SRC：累积到足够帧数后批量处理
        if let Some(ref mut resampler) = rubato_resampler {
            // 追加到声道缓冲
            for c in 0..out_ch {
                rubato_buf[c].extend(
                    mixed.iter().skip(c).step_by(out_ch).map(|&s| s as f64)
                );
            }
            // 循环处理直到缓冲不够
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
                        try_send_or_stop(&tx, DecodedFrame {
                            samples,
                            pts_secs: packet.pts.get() as f64 / src_rate as f64,
                            sample_rate: target_rate,
                            channels: target_ch,
                        }, &stop_rx);
                    }
                    Err(e) => warn!("rubato 重采样失败: {e:?}"),
                }
            }
        } else {
            // 无需重采样，直接发送
            try_send_or_stop(&tx, DecodedFrame {
                samples: mixed,
                pts_secs: packet.pts.get() as f64 / src_rate as f64,
                sample_rate: target_rate,
                channels: target_ch,
            }, &stop_rx);
        }
    }
}

/// 将整个音频文件解码到内存，返回交错 PCM f32 样本。
/// 适用于小文件（如音效、短片段）或离线分析。
pub fn decode_to_memory(path: &Path, tr: u32, tc: u32) -> Result<Vec<f32>, String> {
    let (rx, dec) = Decoder::start(path, tr, tc, Arc::new(AtomicU64::new(0)), None)?;
    let mut all = Vec::new();
    while let Ok(f) = rx.recv_timeout(Duration::from_secs(10)) { all.extend(f.samples); }
    dec.stop();
    if all.is_empty() { Err("解码为空".into()) } else { Ok(all) }
}

/// 音频文件元数据
pub struct Metadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_secs: f64,
    pub has_cover: bool,
}

/// 读取音频文件元数据（标题/艺术家/专辑/封面/时长）
pub fn read_metadata(path: &Path) -> Result<Metadata, String> {
    let file = File::open(path).map_err(|e| format!("无法打开文件: {e}"))?;
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
        .map_err(|e| format!("无法探测格式: {e}"))?;

    // 获取时长
    let duration_secs = format
        .tracks()
        .iter()
        .find(|t| {
            matches!(
                &t.codec_params,
                Some(symphonia::core::codecs::CodecParameters::Audio(p))
                    if p.codec != symphonia::core::codecs::audio::CODEC_ID_NULL_AUDIO
            )
        })
        .and_then(|t| {
            let frames = t.num_frames?;
            let tb = t.time_base?;
            let secs = frames as f64 * tb.numer.get() as f64 / tb.denom.get() as f64;
            if secs > 0.0 { Some(secs) } else { None }
        })
        .unwrap_or(0.0);

    // 读取标签
    let mut title: Option<String> = None;
    let mut artist: Option<String> = None;
    let mut album: Option<String> = None;
    let mut has_cover = false;

    if let Some(rev) = format.metadata().current() {
        for tag in &rev.media.tags {
            if let Some(std) = &tag.std {
                match std {
                    StandardTag::TrackTitle(t) => title = Some(t.to_string()),
                    StandardTag::Artist(t) => artist = Some(t.to_string()),
                    StandardTag::Album(t) => album = Some(t.to_string()),
                    _ => {}
                }
            } else {
                let key = tag.raw.key.to_lowercase();
                if let RawValue::String(s) = &tag.raw.value {
                    let val = s.to_string();
                    match key.as_str() {
                        "title" => title = Some(val),
                        "artist" => artist = Some(val),
                        "album" => album = Some(val),
                        _ => {}
                    }
                }
            }
        }
        has_cover = !rev.media.visuals.is_empty();
    }

    Ok(Metadata {
        title,
        artist,
        album,
        duration_secs,
        has_cover,
    })
}

/// 读取音频文件内嵌封面图（JPEG/PNG 原始字节）
pub fn read_cover(path: &Path) -> Result<Vec<u8>, String> {
    let file = File::open(path).map_err(|e| format!("无法打开文件: {e}"))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let mut format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .map_err(|e| format!("无法探测格式: {e}"))?;

    if let Some(rev) = format.metadata().current() {
        if let Some(visual) = rev.media.visuals.first() {
            if visual.data.is_empty() {
                return Err("封面数据为空".into());
            }
            return Ok(visual.data.to_vec());
        }
    }
    Err("未找到封面".into())
}

/// 快速探测音频文件的采样率（不完整解码，只读文件头）
pub fn probe_sample_rate(path: &Path) -> Option<u32> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe()
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

// ── DSD 解码 ──────────────────────────────────────────────────────────

fn run_dsd(
    path: &Path, target_rate: u32, target_ch: u32,
    tx: Sender<DecodedFrame>, stop_rx: Receiver<()>,
    seek_pos: Option<f64>,
) {
    let decoded = match dsd::decode_file(path) {
        Ok(d) => d,
        Err(e) => { warn!("DSD 解码失败: {e}"); return; }
    };

    let mut pcm = decoded.samples;
    let src_rate = decoded.sample_rate;
    let src_ch = decoded.channels as usize;

    info!("DSD 解码: {} ({}Hz, {}ch)", path.display(), src_rate, src_ch);

    // 跳转
    if let Some(secs) = seek_pos {
        let skip = (secs * src_rate as f64) as usize * src_ch;
        if skip < pcm.len() {
            pcm = pcm.split_off(skip);
        }
    }

    // ── 声道混音到目标声道数 ──
    let out_ch = target_ch as usize;
    let in_ch = src_ch;
    if in_ch != out_ch {
        let in_frames = pcm.len() / in_ch;
        let mut mixed = Vec::with_capacity(in_frames * out_ch);
        for f in 0..in_frames {
            let off = f * in_ch;
            if out_ch == 1 {
                mixed.push(pcm[off..off + in_ch].iter().sum::<f32>() / in_ch as f32);
            } else {
                let l = pcm[off];
                let r = if in_ch >= 2 { pcm[off + 1] } else { l };
                mixed.push(l);
                mixed.push(r);
            }
        }
        pcm = mixed;
    }

    // ── rubato 重采样（如需要）或直通 ──
    let need_resample = (src_rate as i64 - target_rate as i64).abs() > 1;

    if need_resample && !pcm.is_empty() {
        let params = InterpolationParameters {
            sinc_len: 256,
            f_cutoff: 0.95,
            interpolation: InterpolationType::Linear,
            oversampling_factor: 256,
            window: WindowFunction::BlackmanHarris2,
        };
        let mut resampler = SincFixedOut::<f64>::new(
            target_rate as f64 / src_rate as f64,
            params, 1024, out_ch,
        );
        let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];

        let mut pts = 0.0f64;
        let total_frames = pcm.len() / out_ch;
        let mut pos = 0usize;
        while pos < total_frames {
            if stop_rx.try_recv().is_ok() { return; }
            // 每次喂 ~4096 帧
            let end = (pos + 4096).min(total_frames);
            for c in 0..out_ch {
                rubato_buf[c].extend(
                    pcm[pos..end].iter().skip(c).step_by(out_ch).map(|&s| s as f64)
                );
            }
            pos = end;

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
                        try_send_or_stop(&tx, DecodedFrame {
                            samples,
                            pts_secs: pts,
                            sample_rate: target_rate,
                            channels: target_ch,
                        }, &stop_rx);
                        pts += out_frames as f64 / target_rate as f64;
                    }
                    Err(e) => warn!("DSD rubato 重采样失败: {e:?}"),
                }
            }
        }
    } else {
        // 无需重采样，分块直发
        let chunk_samples = 4096 * out_ch;
        let mut pts = 0.0;
        for chunk in pcm.chunks(chunk_samples) {
            if stop_rx.try_recv().is_ok() {
                break;
            }
            if chunk.len() < out_ch {
                continue;
            }
            try_send_or_stop(&tx, DecodedFrame {
                samples: chunk.to_vec(),
                pts_secs: pts,
                sample_rate: target_rate,
                channels: target_ch,
            }, &stop_rx);
            pts += chunk.len() as f64 / (target_rate as f64 * out_ch as f64);
        }
    }
}

// ── WavPack 解码 ──────────────────────────────────────────────────────

fn run_wavpack(
    path: &Path, target_rate: u32, target_ch: u32,
    tx: Sender<DecodedFrame>, stop_rx: Receiver<()>,
    seek_pos: Option<f64>,
) {
    let file = match File::open(path) {
        Ok(f) => f, Err(e) => { warn!("打开 WavPack 失败: {e}"); return; }
    };
    let mut reader = match wavpack_rs::WavPackReader::new(BufReader::new(file)) {
        Ok(r) => r, Err(e) => { warn!("WavPack 解析失败: {e}"); return; }
    };
    let info = reader.info();
    let src_rate = info.sample_rate as u32;
    let src_ch = info.channels as usize;
    info!("WavPack 解码: {} ({}Hz, {}ch, {}bit)", path.display(), src_rate, src_ch, info.bits_per_sample);

    // 解码全部样本，转为 f32 交错
    let max_val = (1i64 << (info.bits_per_sample - 1)) as f32;
    let mut interleaved: Vec<i32> = Vec::new();
    for result in reader.samples() {
        match result {
            Ok(sample) => interleaved.push(sample),
            Err(e) => { warn!("WavPack 解码错误: {e}"); return; }
        }
    }
    let total_frames = interleaved.len() / src_ch;
    let mut pcm = Vec::with_capacity(total_frames * src_ch);
    for f in 0..total_frames {
        for c in 0..src_ch {
            pcm.push(interleaved[f * src_ch + c] as f32 / max_val);
        }
    }

    // 跳转
    if let Some(secs) = seek_pos {
        let skip = (secs * src_rate as f64) as usize * src_ch;
        if skip < pcm.len() { pcm = pcm.split_off(skip); }
    }

    // 声道混音到目标声道数
    let out_ch = target_ch as usize;
    if src_ch != out_ch {
        let in_frames = pcm.len() / src_ch;
        let mut mixed = Vec::with_capacity(in_frames * out_ch);
        for f in 0..in_frames {
            let off = f * src_ch;
            if out_ch == 1 {
                mixed.push(pcm[off..off + src_ch].iter().sum::<f32>() / src_ch as f32);
            } else {
                let l = pcm[off];
                let r = if src_ch >= 2 { pcm[off + 1] } else { l };
                mixed.push(l); mixed.push(r);
            }
        }
        pcm = mixed;
    }

    // 重采样或直发
    let need_resample = (src_rate as i64 - target_rate as i64).abs() > 1;
    if need_resample && !pcm.is_empty() {
        let params = InterpolationParameters {
            sinc_len: 256, f_cutoff: 0.95,
            interpolation: InterpolationType::Linear,
            oversampling_factor: 256,
            window: WindowFunction::BlackmanHarris2,
        };
        let mut resampler = SincFixedOut::<f64>::new(
            target_rate as f64 / src_rate as f64, params, 1024, out_ch,
        );
        let mut rubato_buf: Vec<Vec<f64>> = vec![Vec::new(); out_ch];
        let total_frames2 = pcm.len() / out_ch;
        let mut pos = 0usize;
        while pos < total_frames2 {
            if stop_rx.try_recv().is_ok() { return; }
            let end = (pos + 4096).min(total_frames2);
            for c in 0..out_ch {
                rubato_buf[c].extend(pcm[pos..end].iter().skip(c).step_by(out_ch).map(|&s| s as f64));
            }
            pos = end;
            loop {
                let needed = resampler.nbr_frames_needed();
                if rubato_buf[0].len() < needed { break; }
                let waves_in: Vec<Vec<f64>> = rubato_buf.iter_mut()
                    .map(|buf| buf.drain(..needed).collect()).collect();
                match resampler.process(&waves_in) {
                    Ok(waves_out) => {
                        let out_frames2 = waves_out[0].len();
                        let mut samples = Vec::with_capacity(out_frames2 * out_ch);
                        for f in 0..out_frames2 {
                            for c in 0..out_ch { samples.push(waves_out[c][f] as f32); }
                        }
                        try_send_or_stop(&tx, DecodedFrame {
                            samples, pts_secs: 0.0, sample_rate: target_rate, channels: target_ch,
                        }, &stop_rx);
                    }
                    Err(e) => warn!("WavPack 重采样失败: {e:?}"),
                }
            }
        }
    } else {
        let chunk_samples = 4096 * out_ch;
        let mut pts = 0.0;
        for chunk in pcm.chunks(chunk_samples) {
            if stop_rx.try_recv().is_ok() { break; }
            if chunk.len() < out_ch { continue; }
            try_send_or_stop(&tx, DecodedFrame {
                samples: chunk.to_vec(), pts_secs: pts,
                sample_rate: target_rate, channels: target_ch,
            }, &stop_rx);
            pts += chunk.len() as f64 / (target_rate as f64 * out_ch as f64);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TARGET_CHANNELS, TARGET_SAMPLE_RATE};

    fn test_decode(path: &str) -> Option<u64> {
        let p = std::path::Path::new(path);
        if !p.exists() { return None; }
        let (rx, _decoder) = match Decoder::start(p, TARGET_SAMPLE_RATE, TARGET_CHANNELS, Arc::new(AtomicU64::new(0)), None) {
            Ok(v) => v,
            Err(_) => return None,
        };
        let mut t = 0u64;
        loop { match rx.recv_timeout(Duration::from_secs(5)) { Ok(f) => t += f.samples.len() as u64, Err(_) => break } }
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
            Arc::new(AtomicU64::new(0)), None,
        ).unwrap();
        // 接收少量帧后立即停止
        let mut count = 0u64;
        loop {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(f) => { count += f.samples.len() as u64; if count > 5000 { break; } }
                Err(_) => break,
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
                TARGET_SAMPLE_RATE, TARGET_CHANNELS,
                Arc::new(AtomicU64::new(0)), None,
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
            Arc::new(AtomicU64::new(0)), Some(0.1),
        ).unwrap();
        let mut frames = Vec::new();
        loop { match rx.recv_timeout(Duration::from_secs(3)) { Ok(f) => frames.push(f), Err(_) => break } }
        assert!(!frames.is_empty(), "seek 后应有帧输出");
        // 第一帧的 pts 应该在 0.1s 附近（允许 ±0.03s 误差）
        if let Some(first) = frames.first() {
            let delta = (first.pts_secs - 0.1).abs();
            assert!(delta < 0.03, "seek 时间偏差过大: 期望 0.1s, 实际: {}", first.pts_secs);
        }
    }
}
