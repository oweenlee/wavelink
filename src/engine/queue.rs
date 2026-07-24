//! 播放队列管理

use std::path::Path;

use tracing::debug;

use super::command::{EngineEvent, PlayMode};
use super::state::EngineState;

/// 队列条目（普通文件或 CUE 分轨）
#[derive(Debug, Clone)]
pub(crate) struct QueueEntry {
    /// 显示名称（TrackChanged/QueueChanged 事件用）
    pub display: String,
    /// 实际解码的音频文件路径
    pub audio_file: String,
    /// 文件内起始偏移（秒）
    pub start_secs: f64,
    /// 文件内结束位置（秒），<= 0 表示播放到文件末尾
    pub end_secs: f64,
}

impl QueueEntry {
    pub fn for_file(path: String) -> Self {
        QueueEntry { display: path.clone(), audio_file: path, start_secs: 0.0, end_secs: 0.0 }
    }
    pub fn seek_pos(&self) -> Option<f64> {
        if self.start_secs > 0.0 { Some(self.start_secs) } else { None }
    }
    pub fn end_secs_opt(&self) -> Option<f64> {
        if self.end_secs > 0.0 { Some(self.end_secs) } else { None }
    }
    /// 唯一标识（audio_file + start_secs），用于队列移除时精确匹配
    pub fn unique_key(&self) -> (&str, u64) {
        (&self.audio_file, (self.start_secs * 1000.0) as u64)
    }
}

/// 将路径列表解析为 QueueEntry 列表，展开 .cue 文件中的虚轨
pub(crate) fn resolve_entries(paths: Vec<String>) -> Vec<QueueEntry> {
    let mut entries = Vec::new();
    for p in paths {
        let path = Path::new(&p);
        if path.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case("cue")).unwrap_or(false) {
            match crate::cue::parse_cue(path) {
                Ok(sheet) => {
                    let parent = path.parent().unwrap_or(Path::new(""));
                    for file in &sheet.files {
                        let audio = parent.join(&file.path);
                        let audio_str = audio.to_string_lossy().to_string();
                        for (i, track) in file.tracks.iter().enumerate() {
                            let end = if i + 1 < file.tracks.len() {
                                file.tracks[i + 1].start_secs
                            } else {
                                0.0
                            };
                            let title = track.title.as_deref().unwrap_or(&track.num);
                            entries.push(QueueEntry {
                                display: format!("{} - {}", p, title),
                                audio_file: audio_str.clone(),
                                start_secs: track.start_secs,
                                end_secs: end,
                            });
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!("CUE 解析失败 {p}: {e}");
                }
            }
        } else {
            entries.push(QueueEntry::for_file(p));
        }
    }
    entries
}

// ── 队列推进逻辑 ──

impl EngineState {
    pub(crate) fn advance_queue(&mut self) {
        match self.play_mode {
            PlayMode::Normal => self.advance_normal(),
            PlayMode::RepeatOne => self.advance_repeat_one(),
            PlayMode::RepeatAll => self.advance_repeat_all(),
            PlayMode::Shuffle => self.advance_shuffle(),
        }
    }

    pub(crate) fn advance_normal(&mut self) {
        if !self.queue.is_empty() {
            let next = self.queue.remove(0);
            let match_seamless = self.next_entry.as_ref()
                .map(|e| e.display == next.display)
                .unwrap_or(false);
            if match_seamless {
                self.seamless_switch(&next);
            } else {
                debug!("自动播下一曲: {}", next.display);
                self.play_entry(&next);
            }
        } else {
            self.emit(EngineEvent::PlaybackStopped);
        }
    }

    pub(crate) fn advance_repeat_one(&mut self) {
        if let Some(entry) = self.current_entry.clone() {
            self.queue.insert(0, entry);
        }
        self.advance_normal();
    }

    pub(crate) fn advance_repeat_all(&mut self) {
        if self.queue.is_empty() && !self.original_queue.is_empty() {
            let current = self.current_entry.as_ref().map(|e| &e.display);
            self.queue = self.original_queue.iter()
                .filter(|e| Some(&e.display) != current)
                .cloned()
                .collect();
            if self.queue.is_empty() {
                if let Some(ref entry) = self.current_entry {
                    self.queue.push(entry.clone());
                }
            }
        }
        self.advance_normal();
    }

    pub(crate) fn advance_shuffle(&mut self) {
        if self.queue.is_empty() {
            self.emit(EngineEvent::PlaybackStopped);
            return;
        }
        let idx = fastrand::usize(..self.queue.len());
        let next = self.queue.remove(idx);
        let match_seamless = self.next_entry.as_ref()
            .map(|e| e.display == next.display)
            .unwrap_or(false);
        if match_seamless {
            self.seamless_switch(&next);
        } else {
            debug!("随机播下一曲: {}", next.display);
            self.play_entry(&next);
        }
    }

    pub(crate) fn set_queue(&mut self, paths: Vec<String>) {
        let entries = resolve_entries(paths);
        if entries.is_empty() {
            self.stop_full();
            self.queue.clear();
            self.original_queue.clear();
            return;
        }
        let first = entries[0].clone();
        self.queue = entries[1..].to_vec();
        self.original_queue = entries;
        self.play_entry(&first);
    }

    pub(crate) fn next_track(&mut self) {
        self.stop_playback();
        self.advance_queue();
    }

    pub(crate) fn prev_track(&mut self) {
        use std::sync::atomic::Ordering;
        // 播放超过 3 秒→ 回到开头；否则切回上一曲
        let pos_secs = {
            let samples = self.position.load(Ordering::Acquire) as f64;
            let sr = self.output_sample_rate as f64;
            let ch = self.config.channels as f64;
            samples / (sr * ch)
        };
        if pos_secs > 3.0 {
            self.seek(0.0);
            return;
        }
        if let Some(prev) = self.history.pop() {
            self.play_entry(&prev);
        } else {
            // 无历史，回到开头
            self.seek(0.0);
        }
    }

    pub(crate) fn remove_from_queue(&mut self, idx: usize) {
        // idx 是 player.queue 中的 0-based 位置，0=当前曲目，不允许移除
        if idx == 0 { return; }
        let q_idx = idx - 1;
        if q_idx < self.queue.len() {
            let removed = self.queue.remove(q_idx);
            tracing::info!("从队列移除: {}", removed.display);
            let key = removed.unique_key();
            self.original_queue.retain(|e| e.unique_key() != key);
            self.emit_queue();
        }
    }

    pub(crate) fn set_play_mode(&mut self, mode: PlayMode) {
        self.play_mode = mode;
        tracing::info!("播放模式切换为: {mode:?}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::state::tests::make_state;
    use crossbeam_channel::Receiver;
    use std::time::Duration;

    /// Helper：从事件 rx 中收集除 DurationSecs/Position/QueueChanged 外的下一个事件
    fn next_state_event(rx: &Receiver<EngineEvent>) -> Option<EngineEvent> {
        loop {
            match rx.recv_timeout(Duration::from_secs(2)) {
                Ok(EngineEvent::DurationSecs(_)) | Ok(EngineEvent::Position(_)) | Ok(EngineEvent::QueueChanged(..)) => continue,
                other => return other.ok(),
            }
        }
    }

    #[test]
    fn test_normal_advance_removes_from_queue() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into(), "/tmp/next2.wav".into()],
            PlayMode::Normal,
        );
        let orig_len = state.queue.len();
        state.advance_normal();
        assert!(state.queue.len() < orig_len, "advance_normal 应减少队列");
    }

    #[test]
    fn test_normal_queue_empty_emits_stopped() {
        let (mut state, rx) = make_state(vec![], PlayMode::Normal);
        state.advance_normal();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(matches!(ev, EngineEvent::PlaybackStopped), "预期停止, 收到: {ev:?}");
    }

    #[test]
    fn test_repeat_one_inserts_current_to_front() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/next1.wav".into()],
            PlayMode::RepeatOne,
        );
        let before = state.queue.len();
        if let Some(entry) = state.current_entry.clone() {
            state.queue.insert(0, entry);
        }
        assert_eq!(state.queue.len(), before + 1, "应为 current_entry 插入队首");
        assert_eq!(state.queue[0].display, "/tmp/test.wav", "应插回 current_entry");
    }

    #[test]
    fn test_repeat_all_refills_queue_on_empty() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        let current = state.current_entry.as_ref().map(|e| e.display.clone());
        state.queue = state.original_queue.iter()
            .filter(|e| Some(e.display.as_str()) != current.as_deref())
            .cloned()
            .collect();
        if state.queue.is_empty() {
            if let Some(ref entry) = state.current_entry {
                state.queue.push(entry.clone());
            }
        }
        assert_eq!(state.queue.len(), 2, "RepeatAll 应填入 2 首");
        assert_eq!(state.queue[0].display, "/tmp/a.wav");
        assert_eq!(state.queue[1].display, "/tmp/b.wav");
    }

    #[test]
    fn test_repeat_all_single_track_refills() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        state.current_entry = Some(QueueEntry::for_file("/tmp/a.wav".into()));
        state.original_queue = vec![QueueEntry::for_file("/tmp/a.wav".into())];
        let current = state.current_entry.as_ref().map(|e| e.display.clone());
        state.queue = state.original_queue.iter()
            .filter(|e| Some(e.display.as_str()) != current.as_deref())
            .cloned()
            .collect();
        if state.queue.is_empty() {
            if let Some(ref entry) = state.current_entry {
                state.queue.push(entry.clone());
            }
        }
        assert_eq!(state.queue.len(), 1, "单曲 RepeatAll 应填入到 1");
        assert_eq!(state.queue[0].display, "/tmp/a.wav");
    }

    #[test]
    fn test_shuffle_removes_random_track() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/a.wav".into(), "/tmp/b.wav".into(), "/tmp/c.wav".into()],
            PlayMode::Shuffle,
        );
        let before = state.queue.len();
        if !state.queue.is_empty() {
            let idx = fastrand::usize(..state.queue.len());
            state.queue.remove(idx);
        }
        assert_eq!(state.queue.len(), before - 1, "Shuffle 应移除一首");
    }

    #[test]
    fn test_shuffle_empty_emits_stopped() {
        let (mut state, rx) = make_state(vec![], PlayMode::Shuffle);
        state.advance_shuffle();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(matches!(ev, EngineEvent::PlaybackStopped), "预期停止, 收到: {ev:?}");
    }

    #[test]
    fn test_remove_from_queue_removes_at_index() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/song1.wav".into(), "/tmp/song2.wav".into(), "/tmp/song3.wav".into()],
            PlayMode::Normal,
        );
        state.remove_from_queue(0);
        assert_eq!(state.queue.len(), 3, "不应移除当前曲目");
        state.remove_from_queue(1);
        assert_eq!(state.queue.len(), 2, "应移除一首");
        assert!(!state.queue.iter().any(|e| e.display == "/tmp/song1.wav"), "song1 应从队列移除");
    }

    #[test]
    fn test_remove_from_queue_out_of_bounds() {
        let (mut state, _rx) = make_state(
            vec!["/tmp/song1.wav".into()],
            PlayMode::Normal,
        );
        state.remove_from_queue(5);
        assert_eq!(state.queue.len(), 1, "越界移除不应影响队列");
    }

    #[test]
    fn test_set_play_mode_updates_mode() {
        let (mut state, _rx) = make_state(vec![], PlayMode::Normal);
        assert_eq!(state.play_mode, PlayMode::Normal);
        state.set_play_mode(PlayMode::Shuffle);
        assert_eq!(state.play_mode, PlayMode::Shuffle);
        state.set_play_mode(PlayMode::RepeatAll);
        assert_eq!(state.play_mode, PlayMode::RepeatAll);
    }
}
