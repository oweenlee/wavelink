//! iOS/Android FFI 回调函数。此模块不被 flutter_rust_bridge 扫描，
//! 避免 `*mut f32` 参数导致生成失败。

use jni::objects::JObject;
use jni::sys::{jfloat, jint};
use jni::{JNIEnv, JavaVM};

// ── JVM 引用与音频线程提权钩子 ──

static JAVA_VM: std::sync::OnceLock<JavaVM> = std::sync::OnceLock::new();

/// 只存 JavaVM，不做类加载（无时序风险）。FRB/JNI 静态注册不受影响。
#[no_mangle]
pub extern "system" fn JNI_OnLoad(
    vm: JavaVM,
    _reserved: *mut std::ffi::c_void,
) -> jint {
    let _ = JAVA_VM.set(vm);
    jni::sys::JNI_VERSION_1_6
}

/// 音频线程（Rust 解码/consumer 线程）提权钩子：
/// attach 到 JVM 后调 android.os.Process.setThreadPriority(myTid(), URGENT_AUDIO)。
/// 普通应用用 setpriority 设负 nice 必失败，这是 Android 上有权限的正路。
fn android_elevate_current_thread() -> i32 {
    let Some(vm) = JAVA_VM.get() else {
        crate::api::audio_output::probe_log("提权失败: 无 JavaVM");
        return -1;
    };
    let Ok(mut env) = vm.attach_current_thread() else {
        crate::api::audio_output::probe_log("提权失败: attach 失败");
        return -2;
    };
    let Ok(cls) = env.find_class("android/os/Process") else {
        crate::api::audio_output::probe_log("提权失败: 找不到 Process 类");
        return -3;
    };
    let Ok(tid_val) = env.call_static_method(&cls, "myTid", "()I", &[]) else {
        return -4;
    };
    let Ok(tid) = tid_val.i() else {
        return -5;
    };
    // THREAD_PRIORITY_URGENT_AUDIO = -19
    let r = env.call_static_method(
        &cls,
        "setThreadPriority",
        "(II)V",
        &[jni::objects::JValue::Int(tid), jni::objects::JValue::Int(-19)],
    );
    if r.is_err() {
        crate::api::audio_output::probe_log(&format!("提权失败: setThreadPriority tid={tid}"));
        return -6;
    }
    0
}

/// Kotlin 启动时调用：注册提权钩子到 audio-core（此后所有音频线程启动时自动提权）
#[no_mangle]
pub extern "system" fn Java_com_wavelink_wavelink_1mobile_AudioEngine_nativeRegisterElevateHook(
    _env: JNIEnv,
    _this: JObject,
) {
    audio_core::engine::thread_priority::set_elevate_hook(android_elevate_current_thread);
    crate::api::audio_output::probe_log("提权钩子已注册");
}

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
// 注意函数名必须按 JNI 规范转义：包名 wavelink_mobile 的下划线 → _1。

/// Kotlin AudioEngine.nativeSetVolume：设置引擎音量（音频焦点 duck/恢复用）
#[no_mangle]
pub unsafe extern "system" fn Java_com_wavelink_wavelink_1mobile_AudioEngine_nativeSetVolume(
    _env: JNIEnv,
    _this: JObject,
    volume: jfloat,
) {
    crate::api::engine::engine_set_volume(volume);
}
