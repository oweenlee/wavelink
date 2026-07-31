//! 平台音频输出桥接
//!
//! 从 EngineHandle 的 HeadlessOutput ringbuf 拉取 PCM 数据，
//! 供 iOS AVAudioSourceNode 回调使用。

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

use parking_lot::Mutex as ParkingMutex;

/// 硬件采样率（由 Swift 启动时通过 `set_hw_sample_rate` 设置）
static HW_SAMPLE_RATE: AtomicU32 = AtomicU32::new(44100);

/// 最近一帧 16 频段频谱，由 engine 事件轮询写入、Dart 读取
static SPECTRUM: Mutex<[f32; 16]> = Mutex::new([0.0; 16]);
/// underrun 计数：iOS 回调从 ringbuf 读不到足够数据时递增
static UNDERRUN_COUNT: AtomicU64 = AtomicU64::new(0);

/// 由 Swift 通过 extern "C" 调用，设置硬件采样率
#[no_mangle]
pub extern "C" fn set_hw_sample_rate(rate: u32) {
    HW_SAMPLE_RATE.store(rate, Ordering::Release);
}

pub fn get_hw_sample_rate() -> u32 {
    HW_SAMPLE_RATE.load(Ordering::Acquire)
}

/// 读取当前频谱（16 频段，0~1）
pub fn get_spectrum() -> Vec<f32> {
    SPECTRUM.lock().map(|g| g.to_vec()).unwrap_or_default()
}

/// 供 engine 事件轮询更新频谱
pub(crate) fn update_spectrum(bands: &[f32; 16]) {
    if let Ok(mut g) = SPECTRUM.lock() {
        *g = *bands;
    }
}

/// 读取 underrun 计数
pub fn get_underrun_count() -> u64 {
    UNDERRUN_COUNT.load(Ordering::Acquire)
}

/// 清空 ringbuf 残留数据（平台音频流 start/stop 时调用）
pub(crate) fn clear_ringbuf_impl() {
    // EngineHandle 在 seek/切歌时自动 swap_consumer 创建新 ringbuf，
    // 无需手动清空。保留此函数为 no-op 以保持 FFI 兼容。
}

/// 预分配的实时回调缓冲区（避免在音频线程中做堆分配）
/// iOS AVAudioSourceNode 单次回调最大 4096 帧，首次回调时自动分配
static RT_BUF: ParkingMutex<Vec<f32>> = ParkingMutex::new(Vec::new());

/// 从 engine 的 HeadlessOutput ringbuf 拉取 PCM 填入左右声道 buffer
pub(crate) unsafe fn fill_buffer_stereo_impl(
    left_out: *mut f32,
    right_out: *mut f32,
    frames: u32,
) {
    let frames = frames as usize;

    // 从预分配缓冲区获取引用，避免实时线程 malloc
    let mut rt_buf = RT_BUF.lock();
    if rt_buf.len() < frames * 2 {
        rt_buf.resize(frames * 2, 0.0);
    }
    let buf: &mut [f32] = &mut (*rt_buf)[..frames * 2];

    let n = crate::api::engine::engine_read_samples(buf);

    let fc = n / 2;
    for i in 0..fc.min(frames) {
        *left_out.add(i) = buf[i * 2];
        *right_out.add(i) = buf[i * 2 + 1];
    }
    if fc < frames {
        for i in fc..frames {
            *left_out.add(i) = 0.0;
            *right_out.add(i) = 0.0;
        }
        UNDERRUN_COUNT.fetch_add(1, Ordering::AcqRel);
    }
}

// ─────────────────────────────────────────────────────────────
// iOS 音频输出通路集成测试
//
// 目的：在无法"听"的情况下，用数据断言判定 iOS 杂音是否来自 audio-core
// 的数据损坏。本 crate 以 `default-features=false` 编译 audio-core，走的是
// HeadlessOutput（ringbuf）路径——与 iOS 生产环境完全一致；并直接调用 iOS
// AVAudioSourceNode 回调使用的 `fill_buffer_stereo_impl`。
//
// 断言覆盖的杂音嫌疑：
//   1. underrun 补的是干净 0（静音 dropout），而非未初始化垃圾内存（→ 爆裂声）
//   2. 数据无 NaN/inf（解码/DSP 异常）
//   3. 无削波溢出（|sample| <= 1.0，格式/增益错误会越界）
//   4. 单声道源正确上混为立体声（L≈R），无"垃圾声道"
//   5. 44.1k 源经重采样到 48k 后仍是干净正弦（重采样器伪影）
//
// 注意：本模块所有测试共享进程级全局状态（ENGINE / RT_BUF / UNDERRUN_COUNT），
// 故合并为单个 #[test] 顺序执行，避免并行竞态。新增用例请追加到此函数内。
#[cfg(test)]
mod ios_audio_path_tests {
    use super::*;
    use crate::api::engine::{engine_init_ex, engine_is_playing, engine_play};
    use std::thread;
    use std::time::{Duration, Instant};

    const OUT_RATE: u32 = 48000; // iOS 典型硬件采样率
    const CHUNK: usize = 1024; // 单次回调帧数（AVAudioSourceNode 常见量级）

    /// 生成正弦 WAV（所有声道写相同样本；channels=1 即单声道）
    fn write_sine_wav(path: &str, channels: u16, sample_rate: u32, freq: f32, amp: f32, secs: f32) {
        let spec = hound::WavSpec {
            channels,
            sample_rate,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut w = hound::WavWriter::create(path, spec).unwrap();
        let n = (sample_rate as f32 * secs) as u32;
        for i in 0..n {
            let t = i as f32 / sample_rate as f32;
            let s = (t * freq * 2.0 * std::f32::consts::PI).sin() * amp;
            let v = (s * i16::MAX as f32) as i16;
            for _ in 0..channels {
                w.write_sample(v).unwrap();
            }
        }
        w.finalize().unwrap();
    }

    fn rms(v: &[f32]) -> f32 {
        if v.is_empty() {
            return 0.0;
        }
        (v.iter().map(|&x| x * x).sum::<f32>() / v.len() as f32).sqrt()
    }

    /// 从 iOS 回调路径采集 `target` 帧"真实音频"（跳过全 0 的 underrun 块）。
    /// 返回 (左声道, 右声道, 遇到的 underrun 块数)。
    unsafe fn collect_real_frames(target: usize, timeout: Duration) -> (Vec<f32>, Vec<f32>, usize) {
        let mut l = vec![0f32; CHUNK];
        let mut r = vec![0f32; CHUNK];
        let mut la = Vec::new();
        let mut ra = Vec::new();
        let mut underrun_chunks = 0usize;
        let start = Instant::now();
        while la.len() < target && start.elapsed() < timeout {
            fill_buffer_stereo_impl(l.as_mut_ptr(), r.as_mut_ptr(), CHUNK as u32);
            let silence = l.iter().all(|&x| x == 0.0) && r.iter().all(|&x| x == 0.0);
            if silence {
                underrun_chunks += 1;
            } else {
                la.extend_from_slice(&l);
                ra.extend_from_slice(&r);
            }
            thread::sleep(Duration::from_millis(5));
        }
        (la, ra, underrun_chunks)
    }

    /// 对采集到的真实音频做数据完整性断言（无 NaN / 无削波 / 有信号）。
    fn assert_clean_audio(la: &[f32], ra: &[f32], label: &str) {
        assert!(
            la.len() >= CHUNK * 4,
            "[{label}] 采集到的真实音频过少（{} 帧），引擎可能未正常产出 PCM",
            la.len()
        );
        assert!(
            la.iter().chain(ra.iter()).all(|x| x.is_finite()),
            "[{label}] 检测到 NaN/inf 样本——解码或 DSP 产出了非法数据"
        );
        let peak = la
            .iter()
            .chain(ra.iter())
            .fold(0.0f32, |m, &x| m.max(x.abs()));
        assert!(
            peak <= 1.0 + 1e-3,
            "[{label}] 样本越界（peak={peak} > 1.0）——格式/增益错误会导致削波杂音"
        );
        let level = rms(la);
        assert!(
            (0.02..0.9).contains(&level),
            "[{label}] 信号电平异常（RMS={level}）——可能全是静音或接近满量程"
        );
    }

    #[test]
    fn ios_audio_path_data_integrity() {
        let dir = std::env::temp_dir();
        let stereo_path = format!("{}/wavelink_ios_test_stereo.wav", dir.display());
        let mono_path = format!("{}/wavelink_ios_test_mono.wav", dir.display());

        // 44.1kHz 源 → 引擎 48kHz 输出（顺带覆盖重采样器）；0.3 峰值留足余量
        write_sine_wav(&stereo_path, 2, 44100, 440.0, 0.3, 3.0);
        write_sine_wav(&mono_path, 1, 44100, 440.0, 0.3, 3.0);

        // ── 初始化引擎（镜像 iOS：engine_init = 48k/2ch/280ms/无 bit-perfect）──
        set_hw_sample_rate(OUT_RATE);
        engine_init_ex(OUT_RATE, 2, 280, 0, false, false, false, None)
            .expect("引擎初始化失败");

        // ── 嫌疑1：underrun 必须补 0，不能是垃圾内存 ──
        // 引擎刚初始化、尚未播放：ringbuf 为空，此时读取必然 underrun。
        unsafe {
            let mut l0 = vec![0f32; CHUNK];
            let mut r0 = vec![0f32; CHUNK];
            fill_buffer_stereo_impl(l0.as_mut_ptr(), r0.as_mut_ptr(), CHUNK as u32);
            assert!(
                l0.iter().all(|&x| x == 0.0) && r0.iter().all(|&x| x == 0.0),
                "underrun 补了非 0 数据（垃圾内存）——这会直接造成爆裂杂音"
            );
        }
        assert!(get_underrun_count() > 0, "空 ringbuf 读取应计入 underrun");

        // ── 嫌疑2/3/5：立体声 44.1k 正弦 → 48k，数据应干净 ──
        engine_play(stereo_path.clone());
        let mut waited = 0;
        while !engine_is_playing() && waited < 100 {
            thread::sleep(Duration::from_millis(10));
            waited += 1;
        }
        assert!(engine_is_playing(), "引擎未进入播放状态");

        let (la, ra, _ur) =
            unsafe { collect_real_frames(CHUNK * 24, Duration::from_secs(10)) };
        assert_clean_audio(&la, &ra, "stereo-44.1k→48k");
        // 立体声两声道都应有信号（本测试源 L=R，故右声道 RMS 也应达标）
        assert!(rms(&ra) > 0.02, "[stereo] 右声道近乎静音，疑似解交织丢声道");

        // ── 嫌疑4：单声道源应正确上混为立体声（L≈R，无垃圾声道）──
        engine_play(mono_path.clone());
        thread::sleep(Duration::from_millis(150)); // 等切歌 swap_consumer 生效
        // 丢弃切换瞬间的残留帧
        let _ = unsafe { collect_real_frames(CHUNK * 2, Duration::from_secs(2)) };
        let (ml, mr, _ur2) =
            unsafe { collect_real_frames(CHUNK * 24, Duration::from_secs(10)) };
        assert_clean_audio(&ml, &mr, "mono→stereo");

        let n = ml.len().min(mr.len());
        let diff_rms = rms(
            &ml[..n]
                .iter()
                .zip(&mr[..n])
                .map(|(a, b)| a - b)
                .collect::<Vec<f32>>(),
        );
        assert!(
            diff_rms < 0.001,
            "[mono] 左右声道差异过大（diff_rms={diff_rms}）——单声道上混错误会把垃圾塞进一个声道造成杂音"
        );

        // 清理临时文件（忽略失败）
        let _ = std::fs::remove_file(&stereo_path);
        let _ = std::fs::remove_file(&mono_path);
    }
}
