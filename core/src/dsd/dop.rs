//! DoP（DSD over PCM）打包
//!
//! 将原始 DSD 比特流打包为 DoP 格式的 PCM 样本，使支持 DoP 的 DAC
//! 能够还原出原生 DSD 信号（而非经过 PCM 转换）。
//!
//! DoP 格式（每个 24-bit PCM 样本）：
//! ```text
//!  bit 23..16 : 交替标记 0x05 / 0xFA（DAC 据此识别 DoP 流）
//!  bit 15..0  : 16 个 DSD 比特（MSB 优先，时间上最旧的在前）
//! ```
//!
//! PCM 采样率 = DSD 速率 / 16：
//!   DSD64  (2.8224 MHz) → 176.4 kHz
//!   DSD128 (5.6448 MHz) → 352.8 kHz
//!   DSD256 (11.2896 MHz) → 705.6 kHz
//!
//! 样本以 f32 在管线中传输，编码为 `word / 2^23`（右对齐，24-bit 输出）
//! 或 `(word << 8) / 2^31`（左对齐，32-bit 输出）。24-bit 整数在 f32 中
//! 精确可表示（f32 尾数 24 位），后端用 `round()` 还原可做到逐比特无损。

/// DoP 标记 A（偶数帧）
pub const DOP_MARKER_A: u32 = 0x05;
/// DoP 标记 B（奇数帧）
pub const DOP_MARKER_B: u32 = 0xFA;

/// DoP 支持的最大 PCM 速率（DSD256）。DSD512 的 1.4112 MHz 绝大多数 DAC 不支持。
pub const MAX_DOP_RATE: u32 = 705_600;

/// 由 DSD 原始速率（Hz）计算 DoP 的 PCM 采样率
pub fn dop_pcm_rate(dsd_rate_hz: u32) -> u32 {
    dsd_rate_hz / 16
}

/// 判断某 DSD 速率能否走 DoP（不超过 DAC 常见上限）
pub fn dop_supported(dsd_rate_hz: u32) -> bool {
    dop_pcm_rate(dsd_rate_hz) <= MAX_DOP_RATE
}

/// 组装一个 DoP 24-bit 字，并按 24-bit 有符号语义符号扩展到 i32。
///
/// 标记 0xFA 的第 7 位为 1 → 字的 bit 23 为 1 → 作为 24-bit 有符号数是负数。
/// 必须符号扩展后再除以 2^23，否则 f32 会超过满刻度被后端削峰。
/// DAC 端看到的是低 24 位原始比特（0xFAxxxx），标记不受影响。
#[inline]
fn dop_word(marker: u32, b0: u8, b1: u8) -> i32 {
    let raw = (marker << 16) | ((b0 as u32) << 8) | (b1 as u32);
    if raw & 0x0080_0000 != 0 {
        (raw | 0xFF00_0000) as i32
    } else {
        raw as i32
    }
}

/// 将 24-bit 有符号字编码为管线 f32。
/// left_justify=false：右对齐（`word / 2^23`，24-bit 输出设备）；
/// left_justify=true：左对齐（`(word << 8) / 2^31`，32-bit 输出设备）。
#[inline]
pub fn encode_word(word: i32, left_justify: bool) -> f32 {
    if left_justify {
        (word << 8) as f32 / 2_147_483_648.0
    } else {
        word as f32 / 8_388_608.0
    }
}

/// DoP 打包器（维护标记交替相位）
pub struct DopPacker {
    /// 下一帧是否用标记 B
    marker_b: bool,
    /// 32-bit 输出时左对齐
    left_justify: bool,
}

impl DopPacker {
    /// 创建打包器。left_justify：输出格式为 32-bit 整数时传 true。
    pub fn new(left_justify: bool) -> Self {
        DopPacker {
            marker_b: false,
            left_justify,
        }
    }

    /// 将各声道的原始 DSD 字节打包为交错 DoP f32，追加到 out。
    ///
    /// 每声道每 2 个 DSD 字节产生 1 个 PCM 帧；不足 2 字节的尾部忽略
    /// （调用方应保证按偶数字节喂入，DSF 块大小 4096 天然满足）。
    /// 返回产生的帧数。
    pub fn pack(&mut self, chans: &[&[u8]], out: &mut Vec<f32>) -> usize {
        let ch = chans.len();
        if ch == 0 {
            return 0;
        }
        let frames = chans.iter().map(|c| c.len() / 2).min().unwrap_or(0);
        out.reserve(out.len() + frames * ch);
        for f in 0..frames {
            let marker = if self.marker_b {
                DOP_MARKER_B
            } else {
                DOP_MARKER_A
            };
            self.marker_b = !self.marker_b;
            for c in chans.iter() {
                let w = dop_word(marker, c[f * 2], c[f * 2 + 1]);
                out.push(encode_word(w, self.left_justify));
            }
        }
        frames
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 24-bit 符号扩展（测试期望值用）
    fn se24(raw: u32) -> i32 {
        if raw & 0x0080_0000 != 0 {
            (raw | 0xFF00_0000) as i32
        } else {
            raw as i32
        }
    }

    /// 后端 WASAPI I24 的还原公式（与 output_wasapi.rs 保持一致）
    fn decode_i24(s: f32) -> i32 {
        (s * 8_388_608.0).round().clamp(-8_388_608.0, 8_388_607.0) as i32
    }

    /// 后端 I32（AudioUnit/WASAPI）的还原公式
    fn decode_i32(s: f32) -> i32 {
        (s * 2_147_483_648.0)
            .round()
            .clamp(-2_147_483_648.0, 2_147_483_647.0) as i32
    }

    #[test]
    fn dop_rate_mapping() {
        assert_eq!(dop_pcm_rate(2_822_400), 176_400);
        assert_eq!(dop_pcm_rate(5_644_800), 352_800);
        assert_eq!(dop_pcm_rate(11_289_600), 705_600);
        assert!(dop_supported(2_822_400));
        assert!(dop_supported(11_289_600));
        assert!(!dop_supported(22_579_200), "DSD512 不走 DoP");
    }

    #[test]
    fn marker_alternates() {
        let mut p = DopPacker::new(false);
        // 4 字节 = 2 帧
        let ch0 = [0x00, 0x00, 0x00, 0x00];
        let mut out = Vec::new();
        p.pack(&[&ch0], &mut out);
        assert_eq!(out.len(), 2);
        // 帧0 标记 0x05 → word = 0x050000
        assert_eq!(decode_i24(out[0]), 0x050000);
        // 帧1 标记 0xFA → word = 0xFA0000（24-bit 有符号 = -393216）
        assert_eq!(decode_i24(out[1]), se24(0xFA0000));
        assert_eq!(decode_i24(out[1]), -393216);
    }

    #[test]
    fn marker_phase_persists_across_calls() {
        let mut p = DopPacker::new(false);
        let ch = [0x00, 0x00];
        let mut out = Vec::new();
        p.pack(&[&ch], &mut out); // 帧0: A
        out.clear();
        p.pack(&[&ch], &mut out); // 帧1: B（相位延续）
        assert_eq!(decode_i24(out[0]), se24(0xFA0000));
    }

    #[test]
    fn dsd_bits_placed_in_low_16() {
        let mut p = DopPacker::new(false);
        let ch = [0xAB, 0xCD];
        let mut out = Vec::new();
        p.pack(&[&ch], &mut out);
        // word = 0x05ABCD
        assert_eq!(decode_i24(out[0]), 0x05ABCD);
    }

    #[test]
    fn stereo_interleaved_same_marker() {
        let mut p = DopPacker::new(false);
        let l = [0x11, 0x22];
        let r = [0x33, 0x44];
        let mut out = Vec::new();
        p.pack(&[&l, &r], &mut out);
        assert_eq!(out.len(), 2, "1 帧 × 2 声道");
        // 同一帧左右声道标记相同
        assert_eq!(decode_i24(out[0]), 0x051122);
        assert_eq!(decode_i24(out[1]), 0x053344);
    }

    /// 穷举所有可能的 DoP 字（2 标记 × 65536 数据），
    /// 验证 f32 往返经后端公式还原后逐比特一致。
    #[test]
    fn exhaustive_roundtrip_i24() {
        for marker in [DOP_MARKER_A, DOP_MARKER_B] {
            for data in 0..=0xFFFFu32 {
                let word = se24((marker << 16) | data);
                let s = encode_word(word, false);
                assert_eq!(
                    decode_i24(s),
                    word,
                    "I24 往返失败: marker={marker:#x} data={data:#x}"
                );
            }
        }
    }

    #[test]
    fn exhaustive_roundtrip_i32_left_justified() {
        for marker in [DOP_MARKER_A, DOP_MARKER_B] {
            for data in [0u32, 1, 0x5555, 0xAAAA, 0xFFFE, 0xFFFF] {
                let word = se24((marker << 16) | data);
                let s = encode_word(word, true);
                assert_eq!(
                    decode_i32(s),
                    word << 8,
                    "I32 往返失败: marker={marker:#x} data={data:#x}"
                );
            }
        }
    }

    #[test]
    fn encode_is_exact_in_f32() {
        // 24-bit 字 × 2^N 缩放在 f32 中必须精确（无舍入误差）
        for marker in [DOP_MARKER_A, DOP_MARKER_B] {
            for data in [0u32, 0x8000, 0xFFFF] {
                let word = se24((marker << 16) | data);
                let s = encode_word(word, false);
                assert_eq!(s * 8_388_608.0, word as f32, "右对齐编码应精确可逆");
                let s2 = encode_word(word, true);
                assert_eq!(
                    s2 * 2_147_483_648.0,
                    (word << 8) as f32,
                    "左对齐编码应精确可逆"
                );
            }
        }
    }
}
