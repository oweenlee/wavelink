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

/// iOS 系统运行时改变硬件采样率（键盘音/激活麦克风/路由切换/中断等会触发）：
/// 把引擎输出速率对齐到新硬件速率。必须与 Swift 侧重建 source node 配套调用，
/// 否则引擎产出速率与 source node/硬件失配 → 杂音。不走 Dart（系统介入时 Dart 可能被节流）。
#[no_mangle]
pub extern "C" fn engine_sync_output_rate(rate: u32) {
    crate::api::audio_output::set_hw_sample_rate(rate);
    crate::api::engine::engine_set_output_sample_rate(rate);
}
