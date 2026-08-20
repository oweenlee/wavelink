//! 设备断开自动恢复逻辑

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::unbounded;
use parking_lot::Mutex;
use tracing::{error, info, warn};

use super::command::EngineEvent;
use super::state::EngineState;
use super::worker::spawn_consumer;
use crate::decoder::Decoder;
use crate::dsp::DspPipeline;

impl EngineState {
    /// 设备断开后自动恢复：保存当前位置 → 重建输出 → 从断点继续播放
    pub(crate) fn recover_output(&mut self) {
        crate::diag::log("recover_output: 触发！开始重建输出");
        // 保存当前播放状态
        let entry = match self.current_entry.clone() {
            Some(e) => e,
            None => {
                self.output = None;
                self.output_inner = None;
                return;
            }
        };
        let pos_samples = self.position.load(Ordering::Acquire);
        let pos_secs =
            pos_samples as f64 / (self.output_sample_rate as f64 * self.config.channels as f64);

        // 停止当前播放（不重置 position，不清 current_entry）
        self.playing.store(false, Ordering::Release);
        if let Some(flag) = &self.consumer_stop {
            flag.store(true, Ordering::SeqCst);
        }
        if let Some(d) = &self.decoder {
            d.stop();
        }
        if let Some(d) = &self.next_decoder {
            d.stop();
        }
        if let Some(t) = self.consumer_thread.take() {
            let (done_tx, done_rx) = crossbeam_channel::bounded::<()>(1);
            std::thread::spawn(move || {
                let _ = t.join();
                let _ = done_tx.send(());
            });
            if done_rx.recv_timeout(Duration::from_secs(2)).is_err() {
                warn!("消费者线程 join 超时（2s），放弃等待");
            }
        }
        self.decoder = None;
        self.next_decoder = None;
        self.next_entry = None;
        self.consumer_stop = None;
        self.dsp = None;
        // 当前恢复逻辑固定按 PCM 重建输出/解码器；若不清掉 DoP 标记，
        // 后续 seek 仍会走 DoP 分支，以错误的速率重启解码。
        self.dop_active = false;

        // 丢弃旧输出
        self.output = None;
        self.output_inner = None;
        self.sync_output_inner();

        // 重试打开输出设备（立即尝试，失败后短间隔重试，避免固定 500ms 阻塞）
        let sr = self.config.sample_rate;
        let ch = self.config.channels;
        let mut open_result = None;
        for attempt in 0..4u32 {
            match crate::output::open(
                ch,
                sr,
                self.config.buffer_ms,
                self.config.output_device.as_deref(),
                0,
                self.config.exclusive_mode,
            ) {
                Ok(v) => {
                    open_result = Some(v);
                    break;
                }
                Err(e) => {
                    if attempt < 3 {
                        warn!("设备恢复尝试 {}/4 失败: {e}，150ms 后重试", attempt + 1);
                        std::thread::sleep(Duration::from_millis(150));
                    } else {
                        error!("设备恢复失败，无法重新打开输出: {e}");
                        self.emit(EngineEvent::Error(format!("音频设备恢复失败: {e}")));
                        self.emit(EngineEvent::PlaybackStopped);
                        return;
                    }
                }
            }
        }
        // 循环末尾失败分支已 return，此处 Some 必然成立；仍用 let-else 兜底，
        // 避免未来改动重试逻辑时把 unwrap 变成潜在 panic 点。
        let Some((output, prod, inner, actual_rate)) = open_result else {
            self.emit(EngineEvent::Error(
                "音频设备恢复失败：无可用输出设备".into(),
            ));
            self.emit(EngineEvent::PlaybackStopped);
            return;
        };
        self.output_inner = Some(inner);
        self.output = Some(output);
        self.output_sample_rate = actual_rate;
        self.sync_output_sample_rate();
        self.sync_output_inner();
        let (pcm, actual_sr, actual_ch) = (prod, actual_rate, ch);

        // 从断点位置重新启动解码器
        let seek_secs = entry.start_secs + pos_secs;
        let path_buf = Path::new(&entry.audio_file).to_path_buf();
        let (rx, mut decoder) = match Decoder::start(
            &path_buf,
            actual_sr,
            actual_ch,
            self.position.clone(),
            Some(seek_secs),
            entry.end_secs_opt(),
        ) {
            Ok(v) => v,
            Err(e) => {
                error!("设备恢复后解码失败: {e}");
                self.emit(EngineEvent::Error(format!("设备恢复后解码失败: {e}")));
                self.emit(EngineEvent::PlaybackStopped);
                return;
            }
        };
        let decode_err_rx = decoder
            .take_err_rx()
            .unwrap_or_else(|| crossbeam_channel::bounded(1).1);
        self.decoder = Some(decoder);

        // 重建 DSP 管线
        let dsp = Arc::new(Mutex::new(DspPipeline::new(
            actual_sr,
            actual_ch as usize,
            &self.peq_bands,
            self.crossfeed_enabled,
            self.current_volume,
            self.output_bit_depth,
        )));
        self.apply_dsp_settings(&dsp);
        self.dsp = Some(dsp.clone());
        self.reload_pending_ir();
        self.sync_dsp_latency();

        // 启动消费者线程
        let stop_flag = Arc::new(AtomicBool::new(false));
        self.consumer_stop = Some(stop_flag.clone());
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(
            rx,
            pcm,
            dsp,
            stop_flag,
            self.position.clone(),
            consumer_event_tx,
            ready_tx,
            self.next_rx.clone(),
            actual_sr,
            actual_ch,
            self.config.crossfade_ms,
            self.speed.clone(),
            self.levels.clone(),
            decode_err_rx,
            false,
            self.playback_gen.clone(),
        );
        self.consumer_thread = Some(consumer);

        let output = match self.output.as_ref() {
            Some(o) => o,
            None => {
                error!("设备恢复：输出创建后丢失");
                self.emit(EngineEvent::Error("设备恢复：输出创建后丢失".into()));
                self.emit(EngineEvent::PlaybackStopped);
                return;
            }
        };
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                self.playing.store(true, Ordering::Release);
                info!("设备恢复成功，从 {:.1}s 继续播放", pos_secs);
                self.preload_next();
            }
            _ => {
                error!("设备恢复后消费者启动超时");
                self.emit(EngineEvent::Error("设备恢复后消费者启动超时".into()));
                self.emit(EngineEvent::PlaybackStopped);
            }
        }
    }
}
