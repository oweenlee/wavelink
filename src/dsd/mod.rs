//! DSD 文件解码（DSF / DFF）
//!
//! 使用 dsd-reader crate 读取文件，自研 sinc 滤波器降采样为 PCM f32。

mod convert;

use convert::{convert_channels, output_sample_rate};
use dsd_reader::{DsdRate, DsdReader};
use std::convert::TryFrom;
use std::path::Path;

/// DSD 解码结果（交错的 PCM f32 样本）
pub struct DecodedDsd {
    pub samples: Vec<f32>,
    pub channels: u32,
    pub sample_rate: u32,
}

/// 从 DSF/DFF 文件解码为 PCM f32（交错）
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

#[cfg(test)]
mod tests {
    use super::*;

    /// 不存在的文件应返回错误
    #[test]
    fn test_decode_nonexistent() {
        let result = decode_file(Path::new("/tmp/_nonexistent_dsd.dsf"));
        assert!(result.is_err(), "不存在的文件应报错");
    }
}
