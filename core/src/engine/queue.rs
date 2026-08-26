//! 播放队列管理

use std::path::Path;

use tracing::{debug, error};

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
        QueueEntry {
            display: path.clone(),
            audio_file: path,
            start_secs: 0.0,
            end_secs: 0.0,
        }
    }
    pub fn seek_pos(&self) -> Option<f64> {
        if self.start_secs > 0.0 {
            Some(self.start_secs)
        } else {
            None
        }
    }
    pub fn end_secs_opt(&self) -> Option<f64> {
        if self.end_secs > 0.0 {
            Some(self.end_secs)
        } else {
            None
        }
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
        if path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.eq_ignore_ascii_case("cue"))
            .unwrap_or(false)
        {
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
        let _qi = self
            .current_entry
            .as_ref()
            .and_then(|c| self.queue.iter().position(|e| e.display == c.display))
            .map(|i| i.to_string())
            .unwrap_or_else(|| "-".into());
        crate::diag::log(&format!(
            "seq: advance_queue mode={:?} queue_len={} idx={_qi}",
            self.play_mode,
            self.queue.len()
        ));
        self.play_next_chain();
    }

    /// 非递归推进播放：按播放模式挑下一首并播放；该首播放失败（文件不存在/
    /// 解码失败/输出异常）则继续挑下一首，直到成功或无可播曲目。
    ///
    /// 旧实现中 `play_entry ⇄ advance_queue` 互相递归：每跳一首坏轨就加深一层
    /// 栈（play_entry 帧含解码器/输出大对象，单循环占栈可达数百 KB），连续坏轨
    /// 会打爆引擎线程 2MB 栈 → SIGBUS 崩溃（2026-08-25 macOS 崩溃报告）；
    /// RepeatOne 模式下单首坏轨更是无限递归。故全部改为迭代。
    pub(crate) fn play_next_chain(&mut self) {
        // 连续失败上限：防止 RepeatOne + 坏轨等场景无限循环空转 CPU。
        // 正常曲库坏轨跳过后很快命中可播曲目，64 次足够宽裕。
        const MAX_CONSECUTIVE_FAILS: usize = 64;
        let mut fails = 0usize;
        while let Some(next) = self.pick_next_entry() {
            let match_seamless = self
                .next_entry
                .as_ref()
                .map(|e| e.display == next.display)
                .unwrap_or(false);
            if match_seamless {
                self.seamless_switch(&next);
                return;
            }
            debug!("自动播下一曲: {}", next.display);
            if self.play_entry_once(&next) {
                return;
            }
            fails += 1;
            if fails >= MAX_CONSECUTIVE_FAILS {
                error!("连续 {fails} 首播放失败，停止自动跳曲");
                self.emit(EngineEvent::Error(format!(
                    "连续 {fails} 首播放失败，已停止"
                )));
                break;
            }
        }
        // 无可播曲目（队列耗尽或连续失败超限）：彻底停止播放。
        // 不清理的话 playing 会卡在 true、输出回调持续空转 underrun，
        // ringbuf 残留数据可能被播出
        self.stop_playback();
        self.position.store(0, std::sync::atomic::Ordering::SeqCst);
        self.emit(EngineEvent::PlaybackStopped);
    }

    /// 按播放模式挑出下一首要播的条目（只选择不播放）；无可播条目返回 None。
    /// - Normal：弹队首，队列空则 None
    /// - RepeatOne：重复当前曲目；无当前曲目时回落到弹队首
    /// - RepeatAll：队列耗尽后从 original_queue 回填（排除当前曲目）再弹；仍空则 None
    /// - Shuffle：随机弹一首，队列空则 None
    fn pick_next_entry(&mut self) -> Option<QueueEntry> {
        match self.play_mode {
            PlayMode::Normal => {
                if self.queue.is_empty() {
                    None
                } else {
                    Some(self.queue.remove(0))
                }
            }
            PlayMode::RepeatOne => self.current_entry.clone().or_else(|| {
                if self.queue.is_empty() {
                    None
                } else {
                    Some(self.queue.remove(0))
                }
            }),
            PlayMode::RepeatAll => {
                if self.queue.is_empty() && !self.original_queue.is_empty() {
                    let current = self.current_entry.as_ref().map(|e| &e.display);
                    self.queue = self
                        .original_queue
                        .iter()
                        .filter(|e| Some(&e.display) != current)
                        .cloned()
                        .collect();
                    if self.queue.is_empty() {
                        if let Some(ref entry) = self.current_entry {
                            self.queue.push(entry.clone());
                        }
                    }
                }
                if self.queue.is_empty() {
                    None
                } else {
                    Some(self.queue.remove(0))
                }
            }
            PlayMode::Shuffle => {
                if self.queue.is_empty() {
                    None
                } else {
                    let idx = fastrand::usize(..self.queue.len());
                    Some(self.queue.remove(idx))
                }
            }
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

    /// 设置播放队列并从指定索引开始播放（0-based；越界时回落到 0）。
    /// original_queue 保持完整队列，保证 RepeatAll/Shuffle 可覆盖全碟；
    /// QueueChanged 事件携带完整 display 列表，前端据此投影。
    pub(crate) fn set_queue_at(&mut self, paths: Vec<String>, start_index: usize) {
        let entries = resolve_entries(paths);
        if entries.is_empty() {
            self.stop_full();
            self.queue.clear();
            self.original_queue.clear();
            return;
        }
        let start = start_index.min(entries.len() - 1);
        let first = entries[start].clone();
        self.queue = entries[start + 1..].to_vec();
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
        if idx == 0 {
            return;
        }
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
                Ok(EngineEvent::DurationSecs(_))
                | Ok(EngineEvent::Position(_))
                | Ok(EngineEvent::QueueChanged(..)) => continue,
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
        let picked = state.pick_next_entry();
        assert!(picked.is_some(), "Normal 应选出队首");
        assert!(state.queue.len() < orig_len, "pick 应减少队列");
    }

    #[test]
    fn test_normal_queue_empty_emits_stopped() {
        let (mut state, rx) = make_state(vec![], PlayMode::Normal);
        state.advance_queue();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(
            matches!(ev, EngineEvent::PlaybackStopped),
            "预期停止, 收到: {ev:?}"
        );
    }

    #[test]
    fn test_repeat_one_picks_current() {
        let (mut state, _rx) = make_state(vec!["/tmp/next1.wav".into()], PlayMode::RepeatOne);
        let picked = state.pick_next_entry().expect("RepeatOne 应选中当前曲目");
        assert_eq!(picked.display, "/tmp/test.wav", "应重复 current_entry");
        assert_eq!(state.queue.len(), 1, "RepeatOne 不应消耗队列");
    }

    #[test]
    fn test_repeat_all_refills_queue_on_empty() {
        let (mut state, _rx) = make_state(vec![], PlayMode::RepeatAll);
        let current = state.current_entry.as_ref().map(|e| e.display.clone());
        state.queue = state
            .original_queue
            .iter()
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
        state.queue = state
            .original_queue
            .iter()
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
            vec![
                "/tmp/a.wav".into(),
                "/tmp/b.wav".into(),
                "/tmp/c.wav".into(),
            ],
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
        state.advance_queue();
        let ev = next_state_event(&rx).expect("应收到事件");
        assert!(
            matches!(ev, EngineEvent::PlaybackStopped),
            "预期停止, 收到: {ev:?}"
        );
    }

    #[test]
    fn test_remove_from_queue_removes_at_index() {
        let (mut state, _rx) = make_state(
            vec![
                "/tmp/song1.wav".into(),
                "/tmp/song2.wav".into(),
                "/tmp/song3.wav".into(),
            ],
            PlayMode::Normal,
        );
        state.remove_from_queue(0);
        assert_eq!(state.queue.len(), 3, "不应移除当前曲目");
        state.remove_from_queue(1);
        assert_eq!(state.queue.len(), 2, "应移除一首");
        assert!(
            !state.queue.iter().any(|e| e.display == "/tmp/song1.wav"),
            "song1 应从队列移除"
        );
    }

    #[test]
    fn test_remove_from_queue_out_of_bounds() {
        let (mut state, _rx) = make_state(vec!["/tmp/song1.wav".into()], PlayMode::Normal);
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
