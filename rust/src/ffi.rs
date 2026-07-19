//! iOS/Android FFI 回调函数。此模块不被 flutter_rust_bridge 扫描，
//! 避免 `*mut f32` 参数导致生成失败。

/// iOS AVAudioSourceNode 回调：从 ringbuf 拉取 PCM 数据填入左右声道 buffer
#[no_mangle]
pub unsafe extern "C" fn audio_output_fill_buffer_stereo(
    left_out: *mut f32, right_out: *mut f32, frames: u32,
) {
    crate::api::audio_output::fill_buffer_stereo_impl(left_out, right_out, frames);
}

/// iOS 恢复播放时清空 ringbuf 积压，避免"磁带滑"
#[no_mangle]
pub extern "C" fn audio_output_clear_ringbuf() {
    crate::api::audio_output::clear_ringbuf_impl();
}
