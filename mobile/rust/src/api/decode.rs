use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use audio_core::decoder::DecodedFrame;

/// 解码结果
pub struct DecodeResult {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub channels: u32,
    pub duration_secs: f64,
}

/// 解码音频文件到 PCM f32 交错样本（一次性解完整个文件）
pub fn decode_file(path: String) -> Result<DecodeResult, String> {
    let (sr, ch) = (audio_core::TARGET_SAMPLE_RATE, audio_core::TARGET_CHANNELS);
    let samples = audio_core::decoder::decode_to_memory(Path::new(&path), sr, ch)
        .map_err(|e| format!("解码失败: {e}"))?;

    let duration_secs = samples.len() as f64 / ch as f64 / sr as f64;

    Ok(DecodeResult {
        samples,
        sample_rate: sr,
        channels: ch,
        duration_secs,
    })
}

/// 解码 DSD 文件到 PCM f32
pub fn decode_dsd_file(path: String) -> Result<DecodeResult, String> {
    let dsd = audio_core::dsd::decode_file(Path::new(&path))
        .map_err(|e| format!("DSD 解码失败: {e}"))?;

    let duration_secs = dsd.samples.len() as f64
        / dsd.channels as f64
        / dsd.sample_rate as f64;

    Ok(DecodeResult {
        samples: dsd.samples,
        sample_rate: dsd.sample_rate,
        channels: dsd.channels,
        duration_secs,
    })
}

/// 快速探测音频文件的采样率（不完整解码，只读文件头），失败返回 0
pub fn probe_sample_rate(path: String) -> u32 {
    audio_core::decoder::probe_sample_rate(std::path::Path::new(&path)).unwrap_or(0)
}

/// 检查文件是否是 DSD 格式
pub fn is_dsd_file(path: String) -> bool {
    let p = Path::new(&path);
    p.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("dsf") || e.eq_ignore_ascii_case("dff"))
}

// ── 流式解码 ────────────────────────────────────────────────────

/// 流式解码的 PCM 数据块
pub struct DecodeChunk {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub channels: u32,
}

/// 流式解码器句柄（后台线程持续解码，通过 crossbeam channel 逐块输出）
pub struct StreamDecoder {
    rx: crossbeam_channel::Receiver<DecodedFrame>,
    _dec: audio_core::decoder::Decoder,
    sample_rate: u32,
    channels: u32,
    eof: bool,
}

/// 创建流式解码器，立刻启动后台解码线程
/// 可选 seek_secs：从指定秒数开始解码
pub fn stream_decoder_create(path: String, seek_secs: Option<f64>) -> Result<StreamDecoder, String> {
    let (sr, ch) = (audio_core::TARGET_SAMPLE_RATE, audio_core::TARGET_CHANNELS);
    let (rx, dec) = audio_core::decoder::Decoder::start(
        Path::new(&path),
        sr,
        ch,
        Arc::new(AtomicU64::new(0)),
        seek_secs,
        None,
    )
    .map_err(|e| format!("启动流式解码失败: {e}"))?;

    Ok(StreamDecoder {
        rx,
        _dec: dec,
        sample_rate: sr,
        channels: ch,
        eof: false,
    })
}

/// 获取下一块解码数据（等待最多 300ms 或累积到 ~12288 帧，减少 FFI 调用频率）
pub fn stream_decoder_next_chunk(decoder: &mut StreamDecoder) -> Result<Option<DecodeChunk>, String> {
    if decoder.eof {
        return Ok(None);
    }

    const MAX_FRAMES: usize = 12288;
    let mut all_samples = Vec::new();
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(300);

    while (all_samples.len() / decoder.channels as usize) < MAX_FRAMES
        && std::time::Instant::now() < deadline
    {
        let remaining = deadline - std::time::Instant::now();
        let timeout = if remaining > std::time::Duration::from_millis(5) {
            remaining
        } else {
            break;
        };

        match decoder.rx.recv_timeout(timeout) {
            Ok(frame) => {
                all_samples.extend(frame.samples);
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                break;
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                decoder.eof = true;
                break;
            }
        }
    }

    if all_samples.is_empty() {
        return Ok(None);
    }

    Ok(Some(DecodeChunk {
        samples: all_samples,
        sample_rate: decoder.sample_rate,
        channels: decoder.channels,
    }))
}

/// 停止流式解码
pub fn stream_decoder_stop(decoder: &mut StreamDecoder) {
    decoder._dec.stop();
    decoder.eof = true;
}
