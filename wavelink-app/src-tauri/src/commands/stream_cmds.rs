use tauri::State;
use crate::state::AppState;
use super::lock_or_die;

/// 开始流式播放（网络流媒体）
/// 返回 true 表示启动成功
#[tauri::command]
pub fn play_stream(
    format_hint: Option<String>,
    content_length: Option<u64>,
    state: State<AppState>,
) -> Result<(), String> {
    let handle = state.engine.play_stream(format_hint, content_length).map_err(|e| e.to_string())?;
    *lock_or_die(&state.stream_handle) = Some(handle);
    Ok(())
}

/// 向流式播放写入音频数据
/// 返回实际写入的字节数
#[tauri::command]
pub fn stream_write(data: Vec<u8>, state: State<AppState>) -> usize {
    let guard = lock_or_die(&state.stream_handle);
    match guard.as_ref() {
        Some(sh) => sh.write(&data),
        None => 0,
    }
}

/// 通知流式播放数据结束
#[tauri::command]
pub fn stream_eof(state: State<AppState>) {
    if let Some(sh) = lock_or_die(&state.stream_handle).take() {
        sh.signal_eof();
    }
}
