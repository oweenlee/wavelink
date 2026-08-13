//! 输出设备设置：复用或打开新 output

use std::path::Path;
use std::sync::atomic::Ordering;

use tracing::{error, info, warn};

use crate::decoder;
use crate::output::PcmProducer;

use super::command::EngineEvent;
use super::state::EngineState;

/// 输出设置结果
pub(crate) struct OutputSetup {
    pub pcm: PcmProducer,
    pub actual_sr: u32,
    pub actual_ch: u32,
}

/// 协商最优输出采样率：文件原始率 > 设备支持列表中最近的
pub(crate) fn negotiate_sample_rate(file_sr: u32, supported: &[u32]) -> u32 {
    if supported.contains(&file_sr) {
        return file_sr;
    }
    supported.iter()
        .min_by_key(|&&r| (r as i64 - file_sr as i64).unsigned_abs())
        .copied()
        .unwrap_or(file_sr)
}

/// 为 entry 播放准备音频输出。
///
/// 如果已有 output：
///   - bit-perfect/auto_sample_rate 按源采样率尝试切换
///   - 始终 swap consumer
///
/// 否则：
///   - 获取独占模式（如需）
///   - 打开新 output
pub(crate) fn setup_output_for_entry(
    state: &mut EngineState,
    path_buf: &Path,
    channels: u32,
    sample_rate: u32,
    source_bit_depth: u16,
) -> Result<OutputSetup, ()> {
    if let Some(ref mut output) = state.output {
        // ── 复用已有 output ──
        let need_auto_sr = state.config.auto_sample_rate || state.config.bit_perfect;
        if need_auto_sr {
            let file_sr = if state.config.bit_perfect {
                Some(sample_rate)
            } else {
                decoder::probe_sample_rate(path_buf)
            };
            if let Some(file_sr) = file_sr {
                let supported = output.supported_sample_rates();
                let target_sr = negotiate_sample_rate(file_sr, &supported);
                if target_sr != state.output_sample_rate {
                    match output.set_sample_rate(target_sr) {
                        Ok(new_sr) => {
                            state.output_sample_rate = new_sr;
                            if let Some(ref shared) = state.output_sample_rate_shared {
                                shared.store(new_sr, Ordering::Release);
                            }
                            if target_sr != file_sr {
                                warn!("bit-perfect: 采样率 {}Hz 设备不支持，使用 {}Hz", file_sr, new_sr);
                            }
                            info!("采样率自适应: 文件={}Hz, 输出切换为={}Hz", file_sr, new_sr);
                        }
                        Err(e) => warn!("采样率切换失败，保持当前: {e}"),
                    }
                }
            }
        }
        if state.config.bit_perfect && source_bit_depth > 0 {
            output.set_bit_depth(source_bit_depth);
        }
        let out_sr = state.output_sample_rate;
        let out_ch = state.config.channels;
        let out_bits = if state.config.bit_perfect && source_bit_depth > 0 {
            source_bit_depth as u32
        } else {
            state.output_bit_depth
        };
        state.output_bit_depth = out_bits;
        Ok(OutputSetup {
            pcm: output.swap_consumer(state.config.buffer_ms, out_sr, out_ch),
            actual_sr: out_sr,
            actual_ch: out_ch,
        })
    } else {
        // ── 首次打开 output ──
        if state.config.exclusive_mode {
            crate::exclusive::acquire_exclusive_mode(state.config.output_device.as_deref());
            state.exclusive_mode_acquired = true;
        }
        // Headless 构建（移动端 ringbuf 输出，无真实设备）：打开速率必须用引擎
        // 配置速率（= 平台硬件速率，如 iOS 由 set_hw_sample_rate 提供），不能跟
        // 源文件率走——source node 按硬件速率拉取 ringbuf，产出速率与拉取速率
        // 失配时 44.1k 数据被按 48k 播放 → 音调升高（偏尖锐）。真实后端
        // （cpal/oboe/audiounit）则以源速率配置设备，利于 bit-perfect/减少 SRC。
        #[cfg(not(any(feature = "cpal-backend", feature = "oboe-backend", feature = "audiounit-backend", feature = "wasapi-backend")))]
        let open_sample_rate = state.config.sample_rate;
        #[cfg(any(feature = "cpal-backend", feature = "oboe-backend", feature = "audiounit-backend", feature = "wasapi-backend"))]
        let open_sample_rate = sample_rate;
        match crate::output::open(
            channels,
            open_sample_rate,
            state.config.buffer_ms,
            state.config.output_device.as_deref(),
            source_bit_depth,
            state.config.exclusive_mode,
        ) {
            Ok((output, prod, inner, actual_rate)) => {
                state.output_inner = Some(inner);
                if state.config.bit_perfect && actual_rate != open_sample_rate {
                    warn!("bit-perfect: 请求采样率 {}Hz, 实际得到 {}Hz", open_sample_rate, actual_rate);
                }
                state.output = Some(output);
                state.output_sample_rate = actual_rate;
                state.sync_output_sample_rate();
                state.sync_output_inner();
                let actual_bits = if source_bit_depth > 0 { source_bit_depth as u32 } else { 24 };
                state.output_bit_depth = actual_bits;
                Ok(OutputSetup {
                    pcm: prod,
                    actual_sr: actual_rate,
                    actual_ch: channels,
                })
            }
            Err(e) => {
                error!("打开音频输出失败: {e}");
                state.emit(EngineEvent::Error(format!("打开音频输出失败: {e}")));
                Err(())
            }
        }
    }
}
