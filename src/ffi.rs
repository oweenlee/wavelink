//! C 语言 FFI 绑定。通过 `extern "C"` 导出函数供移动端（Kotlin/Swift）调用。
//!
//! # 约定
//! - 引擎句柄通过不透明指针 `*mut AcEngine` 传递
//! - 字符串参数均为 UTF-8 null-terminated C 字符串，空串 = None
//! - 所有函数统一返回 `AcError`（0=成功，非0=失败），仅查询类函数返回实际值
//! - 事件通过轮询或回调获取，非阻塞
//! - 调用方负责分配 C 结构体内存，FFI 填充内容

use std::collections::VecDeque;
use std::ffi::CStr;
use std::os::raw::{c_char, c_double, c_float, c_int, c_uint, c_void};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::analysis;
use crate::decoder;
use crate::engine::{EngineHandle, EngineEvent, PlayMode};
use crate::dsp::PeqBand;
use crossbeam_channel::Receiver;
use ringbuf::traits::{Consumer, Observer};

// ============================================================
// 统一错误码
// ============================================================

/// FFI 统一错误码（所有 FFI 函数返回值）
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcError {
    /// 成功
    Ok = 0,
    /// 文件不存在
    FileNotFound = 1,
    /// 解码失败
    DecodeFailed = 2,
    /// 打开音频输出失败
    OutputOpenFailed = 3,
    /// 音频设备丢失
    DeviceLost = 4,
    /// 无效参数
    InvalidParam = 5,
    /// 引擎未就绪
    EngineNotReady = 6,
    /// 独占模式获取失败
    ExclusiveModeFailed = 7,
}

impl From<crate::error::EngineError> for AcError {
    fn from(e: crate::error::EngineError) -> Self {
        match e {
            crate::error::EngineError::FileNotFound(_) => AcError::FileNotFound,
            crate::error::EngineError::DecodeFailed(_) => AcError::DecodeFailed,
            crate::error::EngineError::OutputOpenFailed(_) => AcError::OutputOpenFailed,
            crate::error::EngineError::DeviceLost => AcError::DeviceLost,
            crate::error::EngineError::InvalidParam(_) => AcError::InvalidParam,
            crate::error::EngineError::InvalidState(_) => AcError::EngineNotReady,
            crate::error::EngineError::ExclusiveModeFailed(_) => AcError::ExclusiveModeFailed,
        }
    }
}

// ============================================================
// C 兼容数据结构
// ============================================================

/// 引擎事件
///
/// 字符串字段（path）通过调用方提供的缓冲区传出，不再固定长度。
/// 调用方在调用 ac_engine_poll_event 前设置 path / path_cap，
/// 函数填充后设置 path_len 为实际需要的长度（不含 null 终止符）。
#[repr(C)]
pub struct AcEvent {
    /// 事件类型：0=TrackChanged, 1=PlaybackStopped, 2=Position,
    /// 3=DurationSecs, 4=Error, 5=QueueChanged, 6=Spectrum, 7=Levels
    pub event_type: c_int,
    /// 字符串输出缓冲区（调用方分配）
    pub path: *mut c_char,
    /// 缓冲区容量（含 null 终止符位置）
    pub path_cap: c_int,
    /// 实际字符串长度（不含 null 终止符）；若 >= path_cap 表示缓冲区不足
    pub path_len: c_int,
    /// 时间值（Position / DurationSecs）
    pub value: c_double,
    /// 频谱 16 频段（Spectrum）
    pub spectrum: [c_float; 16],
}

/// 音频元数据
///
/// 字符串字段通过调用方提供的缓冲区传出。
/// 调用前设置各字段的 ptr/cap，函数填充后设置 len。
/// 若 len >= cap 表示缓冲区不足，字符串已被截断。
#[repr(C)]
pub struct AcMetadata {
    /// 曲名缓冲区（调用方分配）
    pub title: *mut c_char,
    pub title_cap: c_int,
    pub title_len: c_int,
    /// 艺术家缓冲区
    pub artist: *mut c_char,
    pub artist_cap: c_int,
    pub artist_len: c_int,
    /// 专辑名缓冲区
    pub album: *mut c_char,
    pub album_cap: c_int,
    pub album_len: c_int,
    /// 流派缓冲区
    pub genre: *mut c_char,
    pub genre_cap: c_int,
    pub genre_len: c_int,
    /// 发行年份（0=未知）
    pub year: c_int,
    /// 音轨号（0=未知）
    pub track_number: c_int,
    /// 光盘号（0=未知）
    pub disc_number: c_int,
    /// 时长（秒）
    pub duration_secs: c_double,
    /// 是否含有内嵌封面
    pub has_cover: c_int,
}

/// 音频分析结果（BPM / 调性 / 能量）（BPM / 调性 / 能量）
#[repr(C)]
pub struct AcAnalysis {
    /// BPM 值（0 = 未检测到）
    pub bpm: c_float,
    /// 调性字符串，如 "C"/"Gm"，空串 = 无法识别
    pub key: [c_char; 16],
    /// 能量值（0~1）
    pub energy: c_float,
}

/// 实时音频电平
#[repr(C)]
pub struct AcLevels {
    /// RMS 音量（归一化 0.0~1.0）
    pub rms: c_float,
    /// 峰值（归一化 0.0~1.0）
    pub peak: c_float,
    /// 是否削波（1 = 削波，0 = 正常）
    pub clip: c_int,
}

// ============================================================
// 内部帮助函数
// ============================================================

unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    CStr::from_ptr(ptr).to_str().unwrap_or_else(|e| {
        tracing::warn!("非 UTF-8 C 字符串，已忽略: {e}");
        ""
    })
}

fn write_cstr(dst: &mut [c_char], src: &str) {
    let bytes = src.as_bytes();
    let len = bytes.len().min(dst.len() - 1);
    for (i, &b) in bytes[..len].iter().enumerate() {
        dst[i] = b as c_char;
    }
    dst[len] = 0;
}

/// 写入字符串到原始指针缓冲区，返回实际长度（不含 null）
unsafe fn write_cstr_raw(buf: *mut c_char, cap: c_int, src: &str) -> c_int {
    let bytes = src.as_bytes();
    let write_len = if cap > 0 { bytes.len().min(cap as usize - 1) } else { 0 };
    if write_len > 0 && !buf.is_null() {
        for (i, &b) in bytes[..write_len].iter().enumerate() {
            *buf.add(i) = b as c_char;
        }
        *buf.add(write_len) = 0;
    }
    bytes.len() as c_int
}

/// 写入可选字符串到原始指针缓冲区
unsafe fn write_cstr_raw_opt(buf: *mut c_char, cap: c_int, src: &Option<String>) -> c_int {
    match src {
        Some(ref s) => write_cstr_raw(buf, cap, s),
        None => {
            if !buf.is_null() && cap > 0 { *buf = 0; }
            0
        }
    }
}

fn write_cstr_opt(dst: &mut [c_char], src: &Option<String>) {
    match src {
        Some(s) => write_cstr(dst, s),
        None => dst[0] = 0,
    }
}

// ============================================================
// 引擎
// ============================================================

/// 事件回调函数类型
///
/// - `event`: 指向事件数据的指针（仅在回调执行期间有效）
/// - `user_data`: 调用方自定义上下文指针
pub type AcEventCallback = extern "C" fn(event: *const AcEvent, user_data: *mut c_void);

/// 回调状态（内部使用）
struct CallbackState {
    callback: AcEventCallback,
    user_data: *mut c_void,
    /// 用于停止监听线程
    stop: Arc<AtomicBool>,
    /// 监听线程句柄
    thread: Option<std::thread::JoinHandle<()>>,
}

/// 引擎不透明句柄（FFI 层内部使用）
pub struct AcEngine {
    handle: EngineHandle,
    /// 使用 parking_lot::Mutex：无 poison 机制，避免 FFI 边界 panic（UB）
    events: parking_lot::Mutex<EventState>,
    /// 流式播放的写入句柄（网络流媒体用）
    stream_handle: parking_lot::Mutex<Option<crate::stream::StreamHandle>>,
    /// 事件回调状态
    callback: parking_lot::Mutex<Option<CallbackState>>,
}

struct EventState {
    rx: Receiver<EngineEvent>,
    buf: VecDeque<EngineEvent>,
}

fn fill_ac_event(ev: &EngineEvent, out: &mut AcEvent) {
    match ev {
        EngineEvent::TrackChanged(path) => {
            out.event_type = 0;
            out.path_len = unsafe { write_cstr_raw(out.path, out.path_cap, path) };
        }
        EngineEvent::PlaybackStopped => {
            out.event_type = 1;
            out.path_len = 0;
        }
        EngineEvent::Position(pos) => {
            out.event_type = 2;
            out.value = *pos;
            out.path_len = 0;
        }
        EngineEvent::DurationSecs(dur) => {
            out.event_type = 3;
            out.value = *dur;
            out.path_len = 0;
        }
        EngineEvent::Error(msg) => {
            out.event_type = 4;
            out.path_len = unsafe { write_cstr_raw(out.path, out.path_cap, msg) };
        }
        EngineEvent::QueueChanged(_paths, current) => {
            out.event_type = 5;
            out.path_len = unsafe { write_cstr_raw(out.path, out.path_cap, current) };
        }
        EngineEvent::Spectrum(bands) => {
            out.event_type = 6;
            out.path_len = 0;
            for (i, &b) in bands.iter().enumerate().take(16) {
                out.spectrum[i] = b;
            }
        }
        EngineEvent::Levels(lv) => {
            out.event_type = 7;
            out.value = lv.rms as c_double;
            out.path_len = 0;
            // 复用 spectrum[0] 传 peak，spectrum[1] 传 clip
            out.spectrum[0] = lv.peak;
            out.spectrum[1] = if lv.clip { 1.0 } else { 0.0 };
        }
    }
}

/// 创建引擎实例。返回不透明指针，失败返回 null。
/// output_device 传空串或 null 使用系统默认设备。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_create(
    sample_rate: c_int,
    channels: c_int,
    buffer_ms: c_int,
    crossfade_ms: c_int,
    output_device: *const c_char,
) -> *mut c_void {
    let dev_name = cstr_to_str(output_device);
    let device = if dev_name.is_empty() {
        None
    } else {
        Some(dev_name.to_string())
    };

    let config = crate::EngineConfig {
        sample_rate: sample_rate.max(0) as u32,
        channels: channels.max(0) as u32,
        buffer_ms: buffer_ms.max(0) as u32,
        crossfade_ms: crossfade_ms.max(0) as u32,
        output_device: device,
        ..Default::default()
    };

    let (handle, rx) = EngineHandle::start_with_config(config);
    let engine = Box::new(AcEngine {
        handle,
        events: parking_lot::Mutex::new(EventState {
            rx,
            buf: VecDeque::new(),
        }),
        stream_handle: parking_lot::Mutex::new(None),
        callback: parking_lot::Mutex::new(None),
    });
    Box::into_raw(engine) as *mut c_void
}

/// 销毁引擎实例
#[no_mangle]
pub unsafe extern "C" fn ac_engine_destroy(engine: *mut c_void) {
    if !engine.is_null() {
        let e = Box::from_raw(engine as *mut AcEngine);
        // 停止回调监听线程
        if let Some(cb) = e.callback.lock().take() {
            cb.stop.store(true, Ordering::Release);
            if let Some(t) = cb.thread {
                let _ = t.join();
            }
        }
        drop(e);
    }
}

// ============================================================
// 播放控制
// ============================================================

/// 播放指定文件。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_play(engine: *mut c_void, path: *const c_char) -> c_int {
    if engine.is_null() || path.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.play(cstr_to_str(path).to_string());
    AcError::Ok as c_int
}

/// 播放一组文件（替换当前队列）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_play_queue(
    engine: *mut c_void,
    paths: *const *const c_char,
    count: c_int,
) -> c_int {
    if engine.is_null() || paths.is_null() || count <= 0 {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    let mut vec = Vec::with_capacity(count as usize);
    for i in 0..count as isize {
        let p = *paths.offset(i);
        if !p.is_null() {
            vec.push(cstr_to_str(p).to_string());
        }
    }
    e.handle.play_queue(vec);
    AcError::Ok as c_int
}

/// 暂停播放。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_pause(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.pause();
    AcError::Ok as c_int
}

/// 恢复播放。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_resume(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.resume();
    AcError::Ok as c_int
}

/// 停止播放。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_stop(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.stop();
    AcError::Ok as c_int
}

/// 跳转到指定位置（秒）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_seek(engine: *mut c_void, seconds: c_double) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.seek(seconds);
    AcError::Ok as c_int
}

/// 下一首。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_next_track(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.next_track();
    AcError::Ok as c_int
}

/// 上一首（播放>3s 回开头，≤3s 切上一曲）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_prev_track(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.prev_track();
    AcError::Ok as c_int
}

// ============================================================
// 队列 & 模式
// ============================================================

/// 设置播放模式：0=Normal, 1=RepeatOne, 2=RepeatAll, 3=Shuffle。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_play_mode(engine: *mut c_void, mode: c_int) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let play_mode = match mode {
        1 => PlayMode::RepeatOne,
        2 => PlayMode::RepeatAll,
        3 => PlayMode::Shuffle,
        _ => PlayMode::Normal,
    };
    let e = &*(engine as *const AcEngine);
    e.handle.set_play_mode(play_mode);
    AcError::Ok as c_int
}

/// 从队列中移除指定位置（0-indexed）的曲目。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_remove_from_queue(engine: *mut c_void, index: c_int) -> c_int {
    if engine.is_null() || index < 0 {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.remove_from_queue(index as usize);
    AcError::Ok as c_int
}

// ============================================================
// DSP 控制
// ============================================================

/// 设置音量（0.0 ~ 1.0）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_volume(engine: *mut c_void, volume: c_float) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_volume(volume);
    AcError::Ok as c_int
}

/// 设置 ReplayGain 增益（dB），0 = 关闭 ReplayGain。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_replaygain_gain(engine: *mut c_void, gain_db: c_float) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_replaygain_gain_db(gain_db);
    AcError::Ok as c_int
}

/// 设置 PEQ 单段参数（31 段 ISO 频段）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_peq_band(
    engine: *mut c_void,
    index: c_int,
    freq: c_float,
    gain_db: c_float,
    q: c_float,
) -> c_int {
    if engine.is_null() || index < 0 {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle
        .set_peq_band(index as usize, PeqBand { freq, gain_db, q });
    AcError::Ok as c_int
}

/// 设置立体声展宽（enabled=0 关闭, width=1.0 原始, >1.0 展宽）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_stereo_widener(
    engine: *mut c_void,
    enabled: c_int,
    width: c_float,
) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_stereo_widener(enabled != 0, width);
    AcError::Ok as c_int
}

/// 加载 IR 文件（FIR 卷积 EQ）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_load_ir(engine: *mut c_void, path: *const c_char) -> c_int {
    if engine.is_null() || path.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.load_ir(cstr_to_str(path).to_string());
    AcError::Ok as c_int
}

/// 清除已加载的 IR。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_clear_ir(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.clear_ir();
    AcError::Ok as c_int
}

/// 切换输出设备（移动端 Headless 模式无效）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_output_device(engine: *mut c_void, name: *const c_char) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_output_device(cstr_to_str(name).to_string());
    AcError::Ok as c_int
}

// ============================================================
// 音频捕获
// ============================================================

/// 开始音频输入捕获。sample_rate / channels 为目标格式。
/// 返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_start_capture(
    engine: *mut c_void,
    sample_rate: c_int,
    channels: c_int,
) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.start_capture(sample_rate.max(0) as u32, channels.max(0) as u32);
    AcError::Ok as c_int
}

/// 停止音频输入捕获。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_stop_capture(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.stop_capture();
    AcError::Ok as c_int
}

/// 从捕获缓冲读取 PCM 样本（与 ac_audio_read 对称）。
/// 返回实际读取的样本数，0 表示无数据或失败。
#[no_mangle]
pub unsafe extern "C" fn ac_audio_read_capture(engine: *mut c_void, buffer: *mut c_float, samples: c_int) -> c_int {
    if engine.is_null() || buffer.is_null() || samples <= 0 {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    let inner = match e.handle.capture_inner.read().ok().and_then(|g| g.clone()) {
        Some(i) => i,
        None => return 0,
    };
    let mut guard = inner.consumer.lock();
    let available = guard.occupied_len();
    let to_read = (samples as usize).min(available);
    if to_read == 0 {
        return 0;
    }
    let dst = std::slice::from_raw_parts_mut(buffer, to_read);
    guard.pop_slice(dst) as c_int
}

// ============================================================
// 音频会话管理
// ============================================================

/// 音频会话中断开始（如电话呼入、其他 App 占用了音频），引擎自动暂停播放。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_session_interruption_began(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.session_interruption_began();
    AcError::Ok as c_int
}

/// 音频会话中断结束，引擎自动恢复播放。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_session_interruption_ended(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.session_interruption_ended();
    AcError::Ok as c_int
}

// ============================================================
// 音频读取（移动端 Oboe/AudioUnit 回调用）
// ============================================================

/// 从引擎的 ringbuf 读取 PCM 样本。
/// buffer: 调用方分配的 float 缓冲区
/// samples: 期望读取的样本数（stereo 每帧=2 样本）
/// 返回: 实际读取的样本数（0 = 无数据）
#[no_mangle]
pub unsafe extern "C" fn ac_audio_read(
    engine: *mut c_void,
    buffer: *mut c_float,
    samples: c_int,
) -> c_int {
    if engine.is_null() || buffer.is_null() || samples <= 0 {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    let inner = match e.handle.output_inner.read().ok().and_then(|g| g.clone()) {
        Some(i) => i,
        None => return 0,
    };
    let mut guard = inner.consumer.lock();
    let available = guard.occupied_len();
    let to_read = (samples as usize).min(available);
    if to_read == 0 {
        return 0;
    }
    let dst = std::slice::from_raw_parts_mut(buffer, to_read);
    guard.pop_slice(dst) as c_int
}

// ============================================================
// 查询
// ============================================================

/// 获取当前播放位置（秒）
#[no_mangle]
pub unsafe extern "C" fn ac_engine_position(engine: *const c_void) -> c_double {
    if engine.is_null() {
        return 0.0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.position_secs()
}

/// 获取当前曲目时长（秒）
#[no_mangle]
pub unsafe extern "C" fn ac_engine_duration(engine: *const c_void) -> c_double {
    if engine.is_null() {
        return 0.0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.duration_secs()
}

/// 动态调整输出缓冲时长（毫秒），实时生效。仅 Oboe 后端支持。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_buffer_ms(engine: *mut c_void, ms: c_int) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_buffer_ms(ms.max(0) as u32);
    AcError::Ok as c_int
}

/// 设置播放速度（0.25 ~ 4.0），1.0 = 正常。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_speed(engine: *mut c_void, speed: c_float) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_speed(speed);
    AcError::Ok as c_int
}

/// 获取播放状态（1=正在播放, 0=未播放）
#[no_mangle]
pub unsafe extern "C" fn ac_engine_is_playing(engine: *const c_void) -> c_int {
    if engine.is_null() {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.is_playing() as c_int
}

/// 获取 underrun 计数
#[no_mangle]
pub unsafe extern "C" fn ac_engine_underrun_count(engine: *const c_void) -> c_uint {
    if engine.is_null() {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.underrun_count() as c_uint
}

/// 获取实时音频电平（RMS / 峰值 / 削波标志）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_levels(
    engine: *const c_void,
    out: *mut AcLevels,
) -> c_int {
    if engine.is_null() || out.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    let lv = e.handle.levels();
    let out = &mut *out;
    out.rms = lv.rms;
    out.peak = lv.peak;
    out.clip = lv.clip as c_int;
    AcError::Ok as c_int
}

// ============================================================
// 事件轮询
// ============================================================

/// 轮询一个引擎事件。返回 1 表示有事件写入 out，0 表示无事件。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_poll_event(
    engine: *mut c_void,
    out: *mut AcEvent,
) -> c_int {
    if engine.is_null() || out.is_null() {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    let mut state = e.events.lock();

    // 把 channel 中积压的事件全部拉入 buf
    while let Ok(ev) = state.rx.try_recv() {
        state.buf.push_back(ev);
    }

    // 从 buf 弹出一个
    if let Some(ev) = state.buf.pop_front() {
        let out_ref = &mut *out;
        out_ref.event_type = -1;
        out_ref.path_len = 0;
        out_ref.value = 0.0;
        out_ref.spectrum = [0.0; 16];
        fill_ac_event(&ev, out_ref);
        1
    } else {
        0
    }
}

/// 设置事件回调函数。
///
/// 设置后，引擎事件将通过回调函数推送，无需轮询。
/// 传 callback = null 则禁用回调，恢复轮询模式。
///
/// **重要：** 回调与轮询共享同一个事件 channel，事件会被其中一个消费者取走。
/// 设置回调后不应再调用 ac_engine_poll_event，否则事件会被随机分配到其中一个。
///
/// 注意：回调在独立监听线程中调用，回调函数必须是线程安全的。
/// 回调中的 event 指针仅在回调执行期间有效，不要保存或跨线程传递。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_event_callback(
    engine: *mut c_void,
    callback: Option<AcEventCallback>,
    user_data: *mut c_void,
) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    let mut cb_guard = e.callback.lock();

    // 停止现有监听线程
    if let Some(old) = cb_guard.take() {
        old.stop.store(true, Ordering::Release);
        if let Some(t) = old.thread {
            let _ = t.join();
        }
    }

    // 如果提供了回调，启动监听线程
    if let Some(cb_fn) = callback {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_clone = stop.clone();

        // 从事件 channel 中取出 receiver（与轮询共享同一个 channel）
        // 注意：设置回调后轮询仍可用，但事件会被监听线程消费
        let rx = e.events.lock().rx.clone();

        let thread = std::thread::spawn(move || {
            let mut str_buf = vec![0i8; 4096];
            loop {
                if stop_clone.load(Ordering::Acquire) {
                    break;
                }
                match rx.recv_timeout(std::time::Duration::from_millis(100)) {
                    Ok(ev) => {
                        let mut ac_ev = AcEvent {
                            event_type: 0,
                            path: str_buf.as_mut_ptr(),
                            path_cap: str_buf.len() as c_int,
                            path_len: 0,
                            value: 0.0,
                            spectrum: [0.0; 16],
                        };
                        fill_ac_event(&ev, &mut ac_ev);
                        cb_fn(&ac_ev as *const AcEvent, user_data);
                    }
                    Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
                    Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
                }
            }
        });

        *cb_guard = Some(CallbackState {
            callback: cb_fn,
            user_data,
            stop,
            thread: Some(thread),
        });
    }
}

// ============================================================
// 元数据 & 封面
// ============================================================

/// 读取音频文件元数据。返回 AcError。
///
/// 调用前需设置 meta 中各字符串字段的 ptr/cap，函数填充后设置 len。
#[no_mangle]
pub unsafe extern "C" fn ac_metadata_read(path: *const c_char, meta: *mut AcMetadata) -> c_int {
    if path.is_null() || meta.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let p = Path::new(cstr_to_str(path));
    match decoder::read_metadata(p) {
        Ok(md) => {
            let out = &mut *meta;
            out.title_len = write_cstr_raw_opt(out.title, out.title_cap, &md.title);
            out.artist_len = write_cstr_raw_opt(out.artist, out.artist_cap, &md.artist);
            out.album_len = write_cstr_raw_opt(out.album, out.album_cap, &md.album);
            out.genre_len = write_cstr_raw_opt(out.genre, out.genre_cap, &md.genre);
            out.year = md.year.unwrap_or(0) as c_int;
            out.track_number = md.track_number.unwrap_or(0) as c_int;
            out.disc_number = md.disc_number.unwrap_or(0) as c_int;
            out.duration_secs = md.duration_secs;
            out.has_cover = md.has_cover as c_int;
            AcError::Ok as c_int
        }
        Err(_) => AcError::DecodeFailed as c_int,
    }
}

/// 读取内嵌封面图像。返回原始字节（JPEG/PNG），调用方需用 ac_cover_free 释放。
/// 成功时写入 out_data 和 out_len，返回 AcError_Ok。失败返回对应错误码。
#[no_mangle]
pub unsafe extern "C" fn ac_cover_read(
    path: *const c_char,
    out_data: *mut *mut u8,
    out_len: *mut c_int,
) -> c_int {
    if path.is_null() || out_data.is_null() || out_len.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let p = Path::new(cstr_to_str(path));
    match decoder::read_cover(p) {
        Ok(bytes) => {
            let len = bytes.len();
            let mut boxed = bytes.into_boxed_slice();
            *out_data = boxed.as_mut_ptr();
            *out_len = len as c_int;
            std::mem::forget(boxed);
            AcError::Ok as c_int
        }
        Err(_) => AcError::DecodeFailed as c_int,
    }
}

/// 释放 ac_cover_read 返回的封面数据
#[no_mangle]
pub unsafe extern "C" fn ac_cover_free(data: *mut u8, len: c_int) {
    if data.is_null() || len <= 0 {
        return;
    }
    let slice = std::slice::from_raw_parts_mut(data, len as usize);
    drop(Box::from_raw(slice as *mut [u8]));
}

// ============================================================
// ReplayGain 读取
// ============================================================

/// 读取 ReplayGain 标签。返回 AcError。
/// track_gain_db / album_gain_db 为 dB 值（如 -5.23），无标签时为 0.0。
/// has_track_gain / has_album_gain 指示对应值是否有效。
#[no_mangle]
pub unsafe extern "C" fn ac_replaygain_read(
    path: *const c_char,
    track_gain_db: *mut c_float,
    album_gain_db: *mut c_float,
    has_track_gain: *mut c_int,
    has_album_gain: *mut c_int,
) -> c_int {
    if path.is_null() || track_gain_db.is_null() || album_gain_db.is_null()
        || has_track_gain.is_null() || has_album_gain.is_null()
    { return AcError::InvalidParam as c_int; }
    let p = Path::new(cstr_to_str(path));
    match decoder::read_replaygain(p) {
        Ok(rg) => {
            *track_gain_db = rg.track_gain_db.unwrap_or(0.0);
            *album_gain_db = rg.album_gain_db.unwrap_or(0.0);
            *has_track_gain = rg.track_gain_db.is_some() as c_int;
            *has_album_gain = rg.album_gain_db.is_some() as c_int;
            AcError::Ok as c_int
        }
        Err(_) => AcError::DecodeFailed as c_int,
    }
}

// ============================================================
// 音频分析
// ============================================================

/// 分析音频文件（BPM / 调性 / 能量）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_analyze_file(
    path: *const c_char,
    result: *mut AcAnalysis,
) -> c_int {
    if path.is_null() || result.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let p = Path::new(cstr_to_str(path));
    match analysis::analyze_file(p) {
        Ok(ar) => {
            let out = &mut *result;
            out.bpm = ar.bpm.unwrap_or(0.0);
            write_cstr_opt(&mut out.key, &ar.key);
            out.energy = ar.energy.unwrap_or(0.0);
            AcError::Ok as c_int
        }
        Err(_) => AcError::DecodeFailed as c_int,
    }
}

// ============================================================
// 工具函数
// ============================================================

/// 快速探测音频文件采样率。返回采样率 Hz，失败返回 0。
#[no_mangle]
pub unsafe extern "C" fn ac_probe_sample_rate(path: *const c_char) -> c_int {
    if path.is_null() {
        return 0;
    }
    let p = Path::new(cstr_to_str(path));
    decoder::probe_sample_rate(p).unwrap_or(0) as c_int
}

// ============================================================
// 设备枚举
// ============================================================

/// 列出可用输出设备名称。返回设备数量。
/// out_buf: 连续存储缓冲区，每个设备名占 name_size 字节（含 null 终止符）。
/// max_count: 最多写入的设备数。仅 cpal 后端有效，其他平台返回 0。
#[no_mangle]
pub unsafe extern "C" fn ac_list_output_devices(
    out_buf: *mut c_char,
    name_size: c_int,
    max_count: c_int,
) -> c_int {
    #[cfg(feature = "cpal-backend")]
    {
        if out_buf.is_null() || name_size <= 0 || max_count <= 0 {
            return 0;
        }
        let names = crate::output::list_device_names();
        let count = names.len().min(max_count as usize);
        let slot = name_size as usize;
        for (i, name) in names.iter().take(count).enumerate() {
            let dst = out_buf.add(i * slot);
            let _ = write_cstr_raw(dst, name_size, name);
        }
        count as c_int
    }
    #[cfg(not(feature = "cpal-backend"))]
    {
        let _ = (out_buf, name_size, max_count);
        0
    }
}

// ============================================================
// 流式播放（网络流媒体）
// ============================================================

/// 开始流式播放。平台层负责网络 I/O，通过 ac_stream_write 写入数据。
/// format_hint 为格式提示（如 "mp3", "flac", "aac"），传 null 则自动探测。
/// 返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_engine_play_stream(
    engine: *mut c_void,
    format_hint: *const c_char,
) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    let hint = if format_hint.is_null() {
        None
    } else {
        let s = cstr_to_str(format_hint);
        if s.is_empty() { None } else { Some(s.to_string()) }
    };

    let (handle_tx, handle_rx) = crossbeam_channel::bounded(1);
    let shared_tx = std::sync::Arc::new(handle_tx);

    let cmd = EngineCommand::PlayStream {
        format_hint: hint,
        content_length: None,
        ack: None,
        stream_handle_out: Some(shared_tx),
    };
    let _ = e.handle.tx.send(cmd);

    match handle_rx.recv_timeout(Duration::from_secs(3)) {
        Ok(sh) => {
            *e.stream_handle.lock() = Some(sh);
            AcError::Ok as c_int
        }
        Err(_) => AcError::EngineNotReady as c_int,
    }
}

/// 向流式播放写入音频数据。应在 ac_engine_play_stream 成功后调用。
/// 返回实际写入的字节数，0 表示流已关闭或失败。
#[no_mangle]
pub unsafe extern "C" fn ac_stream_write(
    engine: *mut c_void,
    data: *const u8,
    len: c_int,
) -> c_int {
    if engine.is_null() || data.is_null() || len <= 0 {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    let guard = e.stream_handle.lock();
    match guard.as_ref() {
        Some(sh) => {
            let slice = std::slice::from_raw_parts(data, len as usize);
            sh.write(slice) as c_int
        }
        None => 0,
    }
}

/// 通知流式播放数据已结束（EOF）。返回 AcError。
#[no_mangle]
pub unsafe extern "C" fn ac_stream_eof(engine: *mut c_void) -> c_int {
    if engine.is_null() {
        return AcError::InvalidParam as c_int;
    }
    let e = &*(engine as *const AcEngine);
    if let Some(sh) = e.stream_handle.lock().as_ref() {
        sh.signal_eof();
    }
    AcError::Ok as c_int
}
