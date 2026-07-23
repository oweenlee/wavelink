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
        let pos_secs = pos_samples as f64 / (self.output_sample_rate as f64 * self.config.channels as f64);

        // 停止当前播放（不重置 position，不清 current_entry）
        self.playing.store(false, Ordering::Release);
        if let Some(flag) = &self.consumer_stop { flag.store(true, Ordering::SeqCst); }
        if let Some(d) = &self.decoder { d.stop(); }
        if let Some(d) = &self.next_decoder { d.stop(); }
        if let Some(t) = self.consumer_thread.take() {
            let (done_tx, done_rx) = crossbeam_channel::bounded::<()>(1);
            std::thread::spawn(move || { let _ = t.join(); let _ = done_tx.send(()); });
            if done_rx.recv_timeout(Duration::from_secs(2)).is_err() {
                warn!("消费者线程 join 超时（2s），放弃等待");
            }
        }
        self.decoder = None;
        self.next_decoder = None;
        self.next_entry = None;
        self.consumer_stop = None;
        self.dsp = None;

        // 丢弃旧输出
        self.output = None;
        self.output_inner = None;
        self.sync_output_inner();

        // 等待设备可能恢复（USB DAC 拔出后重新插入需要时间）
        std::thread::sleep(Duration::from_millis(500));

        // 重新打开输出设备
        let sr = self.config.sample_rate;
        let ch = self.config.channels;
        let (pcm, actual_sr, actual_ch) = match crate::output::open(ch, sr, self.config.buffer_ms, self.config.output_device.as_deref()) {
            Ok((output, prod, inner, actual_rate)) => {
                self.output_inner = Some(inner);
                self.output = Some(output);
                self.output_sample_rate = actual_rate;
                self.sync_output_inner();
                (prod, actual_rate, ch)
            }
            Err(e) => {
                error!("设备恢复失败，无法重新打开输出: {e}");
                self.emit(EngineEvent::Error(format!("音频设备恢复失败: {e}")));
                return;
            }
        };

        // 从断点位置重新启动解码器
        let seek_secs = entry.start_secs + pos_secs;
        let path_buf = Path::new(&entry.audio_file).to_path_buf();
        let (rx, decoder) = match Decoder::start(
            &path_buf, actual_sr, actual_ch, self.position.clone(),
            Some(seek_secs), entry.end_secs_opt(),
        ) {
            Ok(v) => v,
            Err(e) => {
                error!("设备恢复后解码失败: {e}");
                self.emit(EngineEvent::Error(format!("设备恢复后解码失败: {e}")));
                return;
            }
        };
        self.decoder = Some(decoder);

        // 重建 DSP 管线
        let dsp = Arc::new(Mutex::new(DspPipeline::new(
            actual_sr, actual_ch as usize, &self.peq_bands,
            true, self.current_volume, 24,
        )));
        self.dsp = Some(dsp.clone());

        // 启动消费者线程
        let stop_flag = Arc::new(AtomicBool::new(false));
        self.consumer_stop = Some(stop_flag.clone());
        let consumer_event_tx = self.internal_event_tx.clone();
        let (ready_tx, ready_rx) = unbounded::<bool>();
        let consumer = spawn_consumer(rx, pcm, dsp, stop_flag, self.position.clone(), consumer_event_tx, ready_tx, self.next_rx.clone(), actual_sr, actual_ch, self.config.crossfade_ms, self.speed.clone(), self.levels.clone());
        self.consumer_thread = Some(consumer);

        let output = self.output.as_ref().expect("output 必须在之前创建");
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(true) => {
                output.resume();
                self.playing.store(true, Ordering::Release);
                info!("设备恢复成功，从 {:.1}s 继续播放", pos_secs);
                self.preload_next();
            }
            _ => {
                error!("设备恢复后消费者启动超时");
            }
        }
    }
}
