//! DSD 文件解码（DSF / DFF）
//!
//! 使用 dsd-reader crate 读取文件，自研 sinc 滤波器降采样为 PCM f32。
//! 支持流式增量解码（内存占用恒定，不加载整个文件）。

mod convert;

/// DoP（DSD over PCM）打包
pub mod dop;

use convert::{convert_channels, output_sample_rate};
use dsd_reader::{DsdRate, DsdReader};
use std::convert::TryFrom;
use std::path::Path;

/// DSD 解码结果（交错的 PCM f32 样本）
pub struct DecodedDsd {
    /// 交错 PCM f32 样本 [L, R, L, R, ...]
    pub samples: Vec<f32>,
    /// 声道数
    pub channels: u32,
    /// 输出采样率（取决于 DSD 速率）
    pub sample_rate: u32,
}

/// 从 DSF/DFF 文件解码为 PCM f32（交错）—— 全量解码，仅用于小文件
pub fn decode_file(path: &Path) -> Result<DecodedDsd, String> {
    let reader = DsdReader::from_container(path.to_path_buf())
        .map_err(|e| format!("DSD 文件打开失败: {e}"))?;

    let channels = reader.channels_num() as u32;
    let rate_val = reader.dsd_rate();
    let dsd_rate = DsdRate::try_from(rate_val as u32)
        .map_err(|_| format!("不支持的 DSD 速率: {rate_val}"))?;
    let sample_rate = output_sample_rate(dsd_rate);

    // 逐声道收集 DSD 原始字节
    let mut chan_bytes: Vec<Vec<u8>> = (0..channels as usize).map(|_| Vec::new()).collect();

    let iter = reader.dsd_iter().map_err(|e| format!("DSD 迭代器创建失败: {e}"))?;
    for (_nread, chan_frames) in iter {
        for (c, frame_data) in chan_frames.into_iter().enumerate() {
            if let Some(buf) = chan_bytes.get_mut(c) {
                buf.extend_from_slice(&frame_data);
            }
        }
    }

    // 转换为 PCM
    let ch_refs: Vec<&[u8]> = chan_bytes.iter().map(|v| v.as_slice()).collect();
    let pcm = convert_channels(&ch_refs, dsd_rate);

    Ok(DecodedDsd {
        samples: pcm,
        channels,
        sample_rate,
    })
}

// ── 流式增量解码 ────────────────────────────────────────────────────────

/// 每次 flush 的 DSD 字节阈值（每声道）。
/// 64KB DSD bytes → boxcar 8x → 65536 stage1 samples → FIR 8x → ~8192 PCM frames
const FLUSH_THRESHOLD: usize = 64 * 1024;

/// FIR 滤波器重叠长度（stage2 的 taps - 1）
const FIR_OVERLAP: usize = 63;

/// 流式 DSD→PCM 解码器。内存占用恒定（约 2×FLUSH_THRESHOLD×channels 字节）。
pub struct StreamingDsdDecoder {
    /// 每声道累积的原始 DSD 字节
    chan_dsd: Vec<Vec<u8>>,
    /// 每声道的 stage1 待处理缓冲（含 FIR 重叠尾部）
    chan_pending: Vec<Vec<f32>>,
    channels: usize,
    dsd_rate: DsdRate,
    sample_rate: u32,
}

impl StreamingDsdDecoder {
    /// 创建流式解码器
    pub fn new(path: &Path) -> Result<Self, String> {
        let reader = DsdReader::from_container(path.to_path_buf())
            .map_err(|e| format!("DSD 文件打开失败: {e}"))?;

        let channels = reader.channels_num();
        let rate_val = reader.dsd_rate();
        let dsd_rate = DsdRate::try_from(rate_val as u32)
            .map_err(|_| format!("不支持的 DSD 速率: {rate_val}"))?;
        let sample_rate = output_sample_rate(dsd_rate);

        Ok(StreamingDsdDecoder {
            chan_dsd: (0..channels).map(|_| Vec::with_capacity(FLUSH_THRESHOLD + 4096)).collect(),
            chan_pending: (0..channels).map(|_| Vec::with_capacity(FLUSH_THRESHOLD / 8 + FIR_OVERLAP)).collect(),
            channels,
            dsd_rate,
            sample_rate,
        })
    }

    /// 获取输出采样率
    pub fn sample_rate(&self) -> u32 { self.sample_rate }
    /// 获取声道数
    pub fn channels(&self) -> usize { self.channels }
    /// 获取 DSD 速率
    pub fn dsd_rate(&self) -> DsdRate { self.dsd_rate }

    /// 喂入一个 DSD 块（来自 dsd_iter 的一帧），返回是否达到 flush 阈值
    pub fn feed(&mut self, chan_frames: &[Box<[u8]>]) -> bool {
        for (c, frame_data) in chan_frames.iter().enumerate() {
            if let Some(buf) = self.chan_dsd.get_mut(c) {
                buf.extend_from_slice(frame_data);
            }
        }
        self.chan_dsd.first().map(|b| b.len() >= FLUSH_THRESHOLD).unwrap_or(false)
    }

    /// 将累积的 DSD 字节转换为交错 PCM f32。可多次调用，内部维护 FIR 重叠状态。
    pub fn flush(&mut self) -> Vec<f32> {
        let ch = self.channels;
        if ch == 0 { return Vec::new(); }

        // 各声道独立转换
        let mut pcm_chs: Vec<Vec<f32>> = Vec::with_capacity(ch);
        for c in 0..ch {
            let dsd_bytes = std::mem::take(&mut self.chan_dsd[c]);
            if dsd_bytes.is_empty() {
                pcm_chs.push(Vec::new());
                continue;
            }
            // Stage 1: boxcar 8x 降采样
            let new_stage1 = convert::stage1_boxcar_pub(&dsd_bytes);
            // 追加到 pending（含上次 FIR 重叠尾部）
            self.chan_pending[c].extend_from_slice(&new_stage1);
            // Stage 2: FIR 8x 降采样（流式，保留重叠）
            let pcm = convert::stage2_fir_streaming(&mut self.chan_pending[c]);
            pcm_chs.push(pcm);
        }

        // 交错
        let frame_count = pcm_chs.iter().map(|p| p.len()).min().unwrap_or(0);
        let mut interleaved = Vec::with_capacity(frame_count * ch);
        for f in 0..frame_count {
            for c in 0..ch {
                interleaved.push(pcm_chs[c][f]);
            }
        }
        interleaved
    }

    /// 最终 flush：处理剩余数据（文件结束时调用）
    pub fn finalize(&mut self) -> Vec<f32> {
        // 将剩余 DSD 字节全部转换
        self.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 不存在的文件应返回错误
    #[test]
    fn test_decode_nonexistent() {
        let result = decode_file(Path::new("/tmp/_nonexistent_dsd.dsf"));
        assert!(result.is_err(), "不存在的文件应报错");
    }

    /// 流式解码器创建失败（不存在文件）
    #[test]
    fn test_streaming_nonexistent() {
        let result = StreamingDsdDecoder::new(Path::new("/tmp/_nonexistent_dsd.dsf"));
        assert!(result.is_err());
    }
}
