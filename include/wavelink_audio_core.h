// wavelink-audio-core C API
// 用于移动端（Kotlin JNI / Swift）调用音频引擎
#ifndef WAVELINK_AUDIO_CORE_H
#define WAVELINK_AUDIO_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ==================== 错误码 ====================

// 所有 FFI 函数统一错误码（部分历史函数仍用 -1/0）
typedef enum {
    AcError_Ok = 0,
    AcError_FileNotFound = 1,
    AcError_DecodeFailed = 2,
    AcError_OutputOpenFailed = 3,
    AcError_DeviceLost = 4,
    AcError_InvalidParam = 5,
    AcError_EngineNotReady = 6,
    AcError_ExclusiveModeFailed = 7,
} AcError;

// ==================== 事件 ====================

// 事件回调函数类型
typedef void (*AcEventCallback)(const AcEvent* event, void* user_data);

// 引擎事件
// 字符串字段通过调用方提供的缓冲区传出。
// 调用前设置 path / path_cap，函数填充后设置 path_len。
typedef struct {
    int event_type;              // 0=TrackChanged, 1=PlaybackStopped, 2=Position,
                                 // 3=DurationSecs, 4=Error, 5=QueueChanged,
                                 // 6=Spectrum, 7=Levels
    char* path;                  // 字符串输出缓冲区（调用方分配）
    int   path_cap;              // 缓冲区容量（含 null 终止符位置）
    int   path_len;              // 实际字符串长度（不含 null）；>= path_cap 表示缓冲区不足
    double value;                // 时间值（Position / DurationSecs）
    float spectrum[16];          // 频谱 16 频段（Spectrum）
                                 // event_type=7 (Levels) 时复用：
                                 //   spectrum[0]=peak, spectrum[1]=clip(1.0/0.0)
                                 //   value=RMS
} AcEvent;

// ==================== 元数据 ====================

typedef struct {
    char title[512];
    char artist[512];
    char album[512];
    char genre[128];
    int  year;
    int  track_number;
    int  disc_number;
    double duration_secs;
    int  has_cover;
} AcMetadata;

// ==================== 分析结果 ====================

typedef struct {
    float bpm;
    char key[16];
    float energy;
} AcAnalysis;

// ==================== 实时音频电平 ====================

typedef struct {
    float rms;    // RMS 音量（归一化 0.0~1.0）
    float peak;   // 峰值（归一化 0.0~1.0）
    int   clip;   // 是否削波（1 = 削波，0 = 正常）
} AcLevels;

// ==================== 引擎生命周期 ====================

// 创建引擎（output_device=NULL 或 "" 表示默认设备）
void* ac_engine_create(int sample_rate, int channels, int buffer_ms,
                       int crossfade_ms, const char* output_device);
void  ac_engine_destroy(void* engine);

// ==================== 播放控制 ====================

void ac_engine_play(void* engine, const char* path);
void ac_engine_play_queue(void* engine, const char* const* paths, int count);
void ac_engine_pause(void* engine);
void ac_engine_resume(void* engine);
void ac_engine_stop(void* engine);
void ac_engine_seek(void* engine, double seconds);
void ac_engine_next_track(void* engine);
void ac_engine_prev_track(void* engine);

// ==================== 队列 & 模式 ====================

// mode: 0=Normal, 1=RepeatOne, 2=RepeatAll, 3=Shuffle
void ac_engine_set_play_mode(void* engine, int mode);
void ac_engine_remove_from_queue(void* engine, int index);

// ==================== DSP 控制 ====================

void ac_engine_set_volume(void* engine, float volume);
void ac_engine_set_speed(void* engine, float speed);
void ac_engine_set_replaygain_gain(void* engine, float gain_db);
void ac_engine_set_peq_band(void* engine, int index, float freq,
                            float gain_db, float q);
void ac_engine_set_stereo_widener(void* engine, int enabled, float width);
void ac_engine_load_ir(void* engine, const char* path);
void ac_engine_clear_ir(void* engine);
void ac_engine_set_output_device(void* engine, const char* name);

// ==================== 音频读取（移动端） ====================

// 从引擎 ringbuf 读取 PCM 样本，返回实际读取的样本数
// 供 Oboe (Android) / AudioUnit (iOS) 回调调用
int ac_audio_read(void* engine, float* buffer, int samples);

// ==================== 音频捕获 ====================

// 开始音频输入捕获（麦克风）
void ac_engine_start_capture(void* engine, int sample_rate, int channels);
// 停止音频输入捕获
void ac_engine_stop_capture(void* engine);
// 从捕获缓冲读取 PCM 样本，返回实际读取的样本数
int ac_audio_read_capture(void* engine, float* buffer, int samples);

// ==================== 音频会话管理 ====================

// 音频会话中断开始（如电话呼入），引擎自动暂停播放。
void ac_engine_session_interruption_began(void* engine);
// 音频会话中断结束，引擎自动恢复播放。
void ac_engine_session_interruption_ended(void* engine);

// ==================== 查询 ====================

double ac_engine_position(const void* engine);
double ac_engine_duration(const void* engine);
int    ac_engine_is_playing(const void* engine);
unsigned int ac_engine_underrun_count(const void* engine);
// 获取实时音频电平（RMS / 峰值 / 削波标志），返回 AcError
int    ac_engine_levels(const void* engine, AcLevels* out);

// ==================== 事件轮询 & 回调 ====================

// 轮询一个事件，返回 1 有事件、0 无事件
// 调用前需设置 out->path 和 out->path_cap
int ac_engine_poll_event(void* engine, AcEvent* out);

// 设置事件回调函数。设置后事件通过回调推送，无需轮询。
// 传 callback = NULL 则禁用回调，恢复轮询模式。
// 回调在独立监听线程中调用，必须线程安全。
void ac_engine_set_event_callback(void* engine, AcEventCallback callback, void* user_data);

// ==================== 元数据 & 封面 ====================

// 读取元数据，返回 0 成功、-1 失败
int ac_metadata_read(const char* path, AcMetadata* meta);

// 读取内嵌封面（JPEG/PNG 原始字节），返回 0 成功
// 调用方用完后必须调用 ac_cover_free(data, len)
int ac_cover_read(const char* path, uint8_t** out_data, int* out_len);
void ac_cover_free(uint8_t* data, int len);

// ==================== ReplayGain ====================

// 读取 ReplayGain 标签。返回 0 成功、-1 失败。
// has_track_gain / has_album_gain 为 1 表示对应值有效，0 表示无标签。
int ac_replaygain_read(const char* path, float* track_gain_db,
                       float* album_gain_db, int* has_track_gain,
                       int* has_album_gain);

// ==================== 音频分析 ====================

int ac_analyze_file(const char* path, AcAnalysis* result);

// ==================== 流式播放（网络流媒体） ====================

// 开始流式播放。平台层负责网络 I/O，通过 ac_stream_write 写入数据。
// format_hint 为格式提示（如 "mp3", "flac", "aac"），传 NULL 则自动探测。
// 返回 0 成功，-1 失败。
int ac_engine_play_stream(void* engine, const char* format_hint);

// 向流式播放写入音频数据。应在 ac_engine_play_stream 成功后调用。
// 返回实际写入的字节数，0 表示流已关闭或失败。
int ac_stream_write(void* engine, const uint8_t* data, int len);

// 通知流式播放数据已结束（EOF）。
void ac_stream_eof(void* engine);

// ==================== 设备枚举 ====================

// 枚举输出设备，返回实际设备数。
// out_buf: 连续存储缓冲区，每个设备名占 name_size 字节（含 null）。
// max_count: 最多写入的设备数。
int ac_list_output_devices(char* out_buf, int name_size, int max_count);

// ==================== 工具 ====================

int ac_probe_sample_rate(const char* path);

#ifdef __cplusplus
}
#endif

#endif // WAVELINK_AUDIO_CORE_H
