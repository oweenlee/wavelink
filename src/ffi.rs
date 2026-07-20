//! C 语言 FFI 绑定。通过 `extern "C"` 导出函数供移动端（Kotlin/Swift）调用。
//!
//! # 约定
//! - 引擎句柄通过不透明指针 `*mut AcEngine` 传递
//! - 字符串参数均为 UTF-8 null-terminated C 字符串，空串 = None
//! - 返回 0 表示成功，非 0 表示失败
//! - 事件通过轮询获取，非阻塞
//! - 调用方负责分配 C 结构体内存，FFI 填充内容

use std::collections::VecDeque;
use std::ffi::CStr;
use std::os::raw::{c_char, c_double, c_float, c_int, c_uint, c_void};
use std::path::Path;

use crate::analysis;
use crate::decoder;
use crate::engine::{EngineHandle, EngineEvent, PlayMode};
use crate::dsp::PeqBand;
use crate::output::headless_inner;
use crossbeam_channel::Receiver;
use ringbuf::traits::{Consumer, Observer};

// ============================================================
// C 兼容数据结构
// ============================================================

/// 引擎事件
/// event_type: 0=TrackChanged, 1=PlaybackStopped, 2=Position,
///             3=DurationSecs, 4=Error, 5=QueueChanged, 6=Spectrum
#[repr(C)]
pub struct AcEvent {
    pub event_type: c_int,
    /// 曲目路径 / 错误消息
    pub path: [c_char; 1024],
    /// 时间值（Position / DurationSecs）
    pub value: c_double,
    /// 频谱 16 频段（Spectrum）
    pub spectrum: [c_float; 16],
}

/// 音频元数据
#[repr(C)]
pub struct AcMetadata {
    /// 曲名
    pub title: [c_char; 512],
    /// 艺术家
    pub artist: [c_char; 512],
    /// 专辑名
    pub album: [c_char; 512],
    /// 流派
    pub genre: [c_char; 128],
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

/// 音频分析结果
#[repr(C)]
pub struct AcAnalysis {
    pub bpm: c_float,
    pub key: [c_char; 16],
    pub energy: c_float,
}

// ============================================================
// 内部帮助函数
// ============================================================

unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    CStr::from_ptr(ptr).to_str().unwrap_or("")
}

fn write_cstr(dst: &mut [c_char], src: &str) {
    let bytes = src.as_bytes();
    let len = bytes.len().min(dst.len() - 1);
    for (i, &b) in bytes[..len].iter().enumerate() {
        dst[i] = b as c_char;
    }
    dst[len] = 0;
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

pub struct AcEngine {
    handle: EngineHandle,
    events: std::sync::Mutex<EventState>,
}

struct EventState {
    rx: Receiver<EngineEvent>,
    buf: VecDeque<EngineEvent>,
}

fn fill_ac_event(ev: &EngineEvent, out: &mut AcEvent) {
    match ev {
        EngineEvent::TrackChanged(path) => {
            out.event_type = 0;
            write_cstr(&mut out.path, path);
        }
        EngineEvent::PlaybackStopped => {
            out.event_type = 1;
        }
        EngineEvent::Position(pos) => {
            out.event_type = 2;
            out.value = *pos;
        }
        EngineEvent::DurationSecs(dur) => {
            out.event_type = 3;
            out.value = *dur;
        }
        EngineEvent::Error(msg) => {
            out.event_type = 4;
            write_cstr(&mut out.path, msg);
        }
        EngineEvent::QueueChanged(_paths, current) => {
            out.event_type = 5;
            write_cstr(&mut out.path, current);
        }
        EngineEvent::Spectrum(bands) => {
            out.event_type = 6;
            for (i, &b) in bands.iter().enumerate().take(16) {
                out.spectrum[i] = b;
            }
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
    };

    let (handle, rx) = EngineHandle::start_with_config(config);
    let engine = Box::new(AcEngine {
        handle,
        events: std::sync::Mutex::new(EventState {
            rx,
            buf: VecDeque::new(),
        }),
    });
    Box::into_raw(engine) as *mut c_void
}

/// 销毁引擎实例
#[no_mangle]
pub unsafe extern "C" fn ac_engine_destroy(engine: *mut c_void) {
    if !engine.is_null() {
        drop(Box::from_raw(engine as *mut AcEngine));
    }
}

// ============================================================
// 播放控制
// ============================================================

#[no_mangle]
pub unsafe extern "C" fn ac_engine_play(engine: *mut c_void, path: *const c_char) {
    if engine.is_null() || path.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.play(cstr_to_str(path).to_string());
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_play_queue(
    engine: *mut c_void,
    paths: *const *const c_char,
    count: c_int,
) {
    if engine.is_null() || paths.is_null() || count <= 0 {
        return;
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
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_pause(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.pause();
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_resume(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.resume();
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_stop(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.stop();
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_seek(engine: *mut c_void, seconds: c_double) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.seek(seconds);
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_next_track(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.next_track();
}

// ============================================================
// 队列 & 模式
// ============================================================

#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_play_mode(engine: *mut c_void, mode: c_int) {
    if engine.is_null() {
        return;
    }
    let play_mode = match mode {
        1 => PlayMode::RepeatOne,
        2 => PlayMode::RepeatAll,
        3 => PlayMode::Shuffle,
        _ => PlayMode::Normal,
    };
    let e = &*(engine as *const AcEngine);
    e.handle.set_play_mode(play_mode);
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_remove_from_queue(engine: *mut c_void, index: c_int) {
    if engine.is_null() || index < 0 {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.remove_from_queue(index as usize);
}

// ============================================================
// DSP 控制
// ============================================================

#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_volume(engine: *mut c_void, volume: c_float) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_volume(volume);
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_replaygain_gain(engine: *mut c_void, gain_db: c_float) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_replaygain_gain_db(gain_db);
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_peq_band(
    engine: *mut c_void,
    index: c_int,
    freq: c_float,
    gain_db: c_float,
    q: c_float,
) {
    if engine.is_null() || index < 0 {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle
        .set_peq_band(index as usize, PeqBand { freq, gain_db, q });
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_stereo_widener(
    engine: *mut c_void,
    enabled: c_int,
    width: c_float,
) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_stereo_widener(enabled != 0, width);
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_load_ir(engine: *mut c_void, path: *const c_char) {
    if engine.is_null() || path.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.load_ir(cstr_to_str(path).to_string());
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_clear_ir(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.clear_ir();
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_set_output_device(engine: *mut c_void, name: *const c_char) {
    if engine.is_null() {
        return;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.set_output_device(cstr_to_str(name).to_string());
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
    let inner = match headless_inner() {
        Some(i) => i,
        None => return 0,
    };
    let mut guard = match inner.consumer.lock() {
        Ok(g) => g,
        Err(_) => return 0,
    };
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

#[no_mangle]
pub unsafe extern "C" fn ac_engine_position(engine: *const c_void) -> c_double {
    if engine.is_null() {
        return 0.0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.position_secs()
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_duration(engine: *const c_void) -> c_double {
    if engine.is_null() {
        return 0.0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.duration_secs()
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_is_playing(engine: *const c_void) -> c_int {
    if engine.is_null() {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.is_playing() as c_int
}

#[no_mangle]
pub unsafe extern "C" fn ac_engine_underrun_count(engine: *const c_void) -> c_uint {
    if engine.is_null() {
        return 0;
    }
    let e = &*(engine as *const AcEngine);
    e.handle.underrun_count() as c_uint
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
    let mut state = e.events.lock().unwrap();

    // 把 channel 中积压的事件全部拉入 buf
    while let Ok(ev) = state.rx.try_recv() {
        state.buf.push_back(ev);
    }

    // 从 buf 弹出一个
    if let Some(ev) = state.buf.pop_front() {
        let out_ref = &mut *out;
        out_ref.event_type = -1;
        out_ref.path = [0; 1024];
        out_ref.value = 0.0;
        out_ref.spectrum = [0.0; 16];
        fill_ac_event(&ev, out_ref);
        1
    } else {
        0
    }
}

// ============================================================
// 元数据 & 封面
// ============================================================

/// 读取音频文件元数据。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn ac_metadata_read(path: *const c_char, meta: *mut AcMetadata) -> c_int {
    if path.is_null() || meta.is_null() {
        return -1;
    }
    let p = Path::new(cstr_to_str(path));
    match decoder::read_metadata(p) {
        Ok(md) => {
            let out = &mut *meta;
            write_cstr_opt(&mut out.title, &md.title);
            write_cstr_opt(&mut out.artist, &md.artist);
            write_cstr_opt(&mut out.album, &md.album);
            write_cstr_opt(&mut out.genre, &md.genre);
            out.year = md.year.unwrap_or(0) as c_int;
            out.track_number = md.track_number.unwrap_or(0) as c_int;
            out.disc_number = md.disc_number.unwrap_or(0) as c_int;
            out.duration_secs = md.duration_secs;
            out.has_cover = md.has_cover as c_int;
            0
        }
        Err(_) => -1,
    }
}

/// 读取内嵌封面图像。返回原始字节（JPEG/PNG），调用方需用 ac_cover_free 释放。
/// 成功时写入 out_data 和 out_len，返回 0。失败返回非 0。
#[no_mangle]
pub unsafe extern "C" fn ac_cover_read(
    path: *const c_char,
    out_data: *mut *mut u8,
    out_len: *mut c_int,
) -> c_int {
    if path.is_null() || out_data.is_null() || out_len.is_null() {
        return -1;
    }
    let p = Path::new(cstr_to_str(path));
    match decoder::read_cover(p) {
        Ok(bytes) => {
            let len = bytes.len();
            // 泄漏 Vec 的堆内存，通过 out_data 返回指针
            let mut boxed = bytes.into_boxed_slice();
            *out_data = boxed.as_mut_ptr();
            *out_len = len as c_int;
            // 阻止 drop，调用方负责 ac_cover_free
            std::mem::forget(boxed);
            0
        }
        Err(_) => -1,
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

/// 读取 ReplayGain 标签。返回 0 成功，-1 失败。
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
    { return -1; }
    let p = Path::new(cstr_to_str(path));
    match decoder::read_replaygain(p) {
        Ok(rg) => {
            *track_gain_db = rg.track_gain_db.unwrap_or(0.0);
            *album_gain_db = rg.album_gain_db.unwrap_or(0.0);
            *has_track_gain = rg.track_gain_db.is_some() as c_int;
            *has_album_gain = rg.album_gain_db.is_some() as c_int;
            0
        }
        Err(_) => -1,
    }
}

// ============================================================
// 音频分析
// ============================================================

/// 分析音频文件（BPM / 调性 / 能量）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn ac_analyze_file(
    path: *const c_char,
    result: *mut AcAnalysis,
) -> c_int {
    if path.is_null() || result.is_null() {
        return -1;
    }
    let p = Path::new(cstr_to_str(path));
    match analysis::analyze_file(p) {
        Ok(ar) => {
            let out = &mut *result;
            out.bpm = ar.bpm.unwrap_or(0.0);
            write_cstr_opt(&mut out.key, &ar.key);
            out.energy = ar.energy.unwrap_or(0.0);
            0
        }
        Err(_) => -1,
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
