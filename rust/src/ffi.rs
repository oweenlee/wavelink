//! iOS/Android FFI 回调函数。此模块不被 flutter_rust_bridge 扫描，
//! 避免 `*mut f32` 参数导致生成失败。

use jni::objects::{JFloatArray, JObject, ReleaseMode};
use jni::sys::{jboolean, jint};
use jni::JNIEnv;

/// iOS AVAudioSourceNode 回调：从 ringbuf 拉取 PCM 数据填入左右声道 buffer
#[no_mangle]
pub unsafe extern "C" fn audio_output_fill_buffer_stereo(
    left_out: *mut f32, right_out: *mut f32, frames: u32,
) {
    crate::api::audio_output::fill_buffer_stereo_impl(left_out, right_out, frames);
}

/// Android Kotlin 原生泵：从 ringbuf 拉取最多 `max_frames` 帧交错立体声 PCM
/// 写入 `out`，返回实际写入的帧数。
#[no_mangle]
pub unsafe extern "C" fn audio_output_fill_interleaved(
    out: *mut f32, max_frames: u32,
) -> u32 {
    if out.is_null() || max_frames == 0 {
        return 0;
    }
    let buf = std::slice::from_raw_parts_mut(out, max_frames as usize * 2);
    crate::api::audio_output::fill_interleaved_impl(buf, max_frames)
}

/// iOS 恢复播放时清空 ringbuf 积压，避免"磁带滑"
#[no_mangle]
pub extern "C" fn audio_output_clear_ringbuf() {
    crate::api::audio_output::clear_ringbuf_impl();
}

/// iOS 播放门控：Swift 主线程在 play/pause/resume/stop 时设置。
/// 渲染回调在 fill_buffer 内无锁读取（AtomicBool）；false 时输出静音。
/// 取代 Swift 侧跨线程 Bool 标志，消除音频线程数据竞争。
#[no_mangle]
pub extern "C" fn audio_output_set_playing(playing: bool) {
    crate::api::audio_output::set_playing_impl(playing);
}

/// iOS 系统运行时改变硬件采样率（键盘音/激活麦克风/路由切换/中断等会触发）：
/// 把引擎输出速率对齐到新硬件速率。必须与 Swift 侧重建 source node 配套调用，
/// 否则引擎产出速率与 source node/硬件失配 → 杂音。不走 Dart（系统介入时 Dart 可能被节流）。
#[no_mangle]
pub extern "C" fn engine_sync_output_rate(rate: u32) {
    crate::api::audio_output::set_hw_sample_rate(rate);
    crate::api::engine::engine_set_output_sample_rate(rate);
}

// ─────────────────────────────────────────────────────────────
// Android JNI 直读绑定（Kotlin AudioEngine 原生泵）
//
// 采用 `Java_` 前缀静态绑定：只要 so 被 JVM 加载（System.loadLibrary），
// native 方法符号即可经 dlsym 解析，无需 JNI_OnLoad/RegisterNatives，
// 规避了 JNI_OnLoad 阶段 find_class 的类加载时序问题。
// 注意函数名必须与 Kotlin 类包名/方法名完全一致。

/// Kotlin AudioEngine.nativeFillInterleaved：拉取交错 PCM 填入 Kotlin 侧 FloatArray
#[no_mangle]
pub unsafe extern "system" fn Java_com_wavelink_wavelink_mobile_AudioEngine_nativeFillInterleaved(
    mut env: JNIEnv,
    _this: JObject,
    arr: JFloatArray,
    max_frames: jint,
) -> jint {
    if max_frames <= 0 {
        return 0;
    }
    match env.get_array_elements(&arr, ReleaseMode::CopyBack) {
        Ok(mut elements) => {
            let len = ((max_frames as usize) * 2).min(elements.len());
            let buf = &mut elements[..len];
            crate::api::audio_output::fill_interleaved_impl(buf, max_frames as u32) as jint
        }
        Err(_) => 0,
    }
}

/// Kotlin AudioEngine.nativeSetPlaying：播放门控（与 iOS 同一标志）
#[no_mangle]
pub unsafe extern "system" fn Java_com_wavelink_wavelink_mobile_AudioEngine_nativeSetPlaying(
    _env: JNIEnv,
    _this: JObject,
    playing: jboolean,
) {
    crate::api::audio_output::set_playing_impl(playing != 0);
}

/// Kotlin AudioEngine.nativeClearRingbuf：清空 ringbuf 积压（seek/pause 用）
#[no_mangle]
pub unsafe extern "system" fn Java_com_wavelink_wavelink_mobile_AudioEngine_nativeClearRingbuf(
    _env: JNIEnv,
    _this: JObject,
) {
    crate::api::audio_output::clear_ringbuf_impl();
}
