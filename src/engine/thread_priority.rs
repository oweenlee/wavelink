//! 跨平台音频线程优先级提升
//!
//! 在实时音频回调线程和解码线程中调用，降低被系统调度器抢占的概率，
//! 减少音频 glitch。

/// 提升当前线程为高优先级音频线程。
///
/// 各平台策略：
/// - macOS / iOS: QOS_CLASS_USER_INTERACTIVE
/// - Android: setpriority(PRIO_PROCESS, 0, -16)
/// - Linux: SCHED_FIFO priority 80
/// - Windows: THREAD_PRIORITY_TIME_CRITICAL
///
/// 失败时仅打印日志，不 panic（非关键路径）。
pub fn elevate_audio_thread() {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        extern "C" {
            fn pthread_set_qos_class_self_np(class: u32, offset: i32) -> i32;
        }
        // QOS_CLASS_USER_INTERACTIVE = 0x21
        let ret = unsafe { pthread_set_qos_class_self_np(0x21, 0) };
        if ret != 0 {
            tracing::warn!("设置 QoS 失败: {ret}");
        }
    }

    #[cfg(target_os = "android")]
    {
        extern "C" {
            fn setpriority(which: i32, who: u32, prio: i32) -> i32;
        }
        // PRIO_PROCESS = 0, who = 0 (当前线程)
        let ret = unsafe { setpriority(0, 0, -16) };
        if ret != 0 {
            tracing::warn!("Android setpriority 失败: {ret}");
        }
    }

    #[cfg(target_os = "linux")]
    {
        extern "C" {
            fn pthread_self() -> u64;
            fn pthread_setschedparam(thread: u64, policy: i32, param: *const SchedParam) -> i32;
        }
        #[repr(C)]
        struct SchedParam {
            sched_priority: i32,
        }
        // SCHED_FIFO = 1
        let param = SchedParam { sched_priority: 80 };
        let ret = unsafe { pthread_setschedparam(pthread_self(), 1, &param) };
        if ret != 0 {
            tracing::warn!("Linux SCHED_FIFO 设置失败: {ret}（可能需要 CAP_SYS_NICE）");
        }
    }

    #[cfg(target_os = "windows")]
    {
        extern "system" {
            fn GetCurrentThread() -> isize;
            fn SetThreadPriority(thread: isize, priority: i32) -> i32;
        }
        // THREAD_PRIORITY_TIME_CRITICAL = 15
        let ret = unsafe { SetThreadPriority(GetCurrentThread(), 15) };
        if ret == 0 {
            tracing::warn!("Windows SetThreadPriority 失败");
        }
    }
}
