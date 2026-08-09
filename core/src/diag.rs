//! 低层诊断日志：Android 进 logcat（tag WaveLinkCore），其余平台 stderr。
//!
//! 不依赖 tracing subscriber（移动端 headless 场景未必初始化），
//! 用于关键路径的无条件诊断输出，仅 crate 内部使用。

#[cfg(target_os = "android")]
#[link(name = "log")]
extern "C" {
    fn __android_log_write(prio: i32, tag: *const u8, text: *const u8) -> i32;
}

/// 输出一条诊断日志（Android → logcat，其余平台 stderr）
pub fn log(msg: &str) {
    #[cfg(target_os = "android")]
    {
        let mut b = Vec::with_capacity(msg.len() + 1);
        b.extend_from_slice(msg.as_bytes());
        b.push(0);
        unsafe { __android_log_write(4, b"WaveLinkCore\0".as_ptr(), b.as_ptr()) };
    }
    #[cfg(not(target_os = "android"))]
    eprintln!("[core-diag] {msg}");
}
