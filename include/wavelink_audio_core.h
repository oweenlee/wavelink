// wavelink-audio-core C API
// 用于移动端（Kotlin JNI / Swift）调用音频引擎
#ifndef WAVELINK_AUDIO_CORE_H
#define WAVELINK_AUDIO_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ==================== 事件 ====================

typedef struct {
    int event_type;              // 0=TrackChanged, 1=PlaybackStopped, 2=Position,
                                 // 3=DurationSecs, 4=Error, 5=QueueChanged, 6=Spectrum
    char path[1024];             // 曲目路径（TrackChanged）/ 错误消息（Error）
    double value;                // 时间值（Position / DurationSecs）
    float spectrum[16];          // 频谱 16 频段（Spectrum）
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

// ==================== 查询 ====================

double ac_engine_position(const void* engine);
double ac_engine_duration(const void* engine);
int    ac_engine_is_playing(const void* engine);
unsigned int ac_engine_underrun_count(const void* engine);

// ==================== 事件轮询 ====================

// 轮询一个事件，返回 1 有事件、0 无事件
int ac_engine_poll_event(void* engine, AcEvent* out);

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
// out_names: 设备名数组（每项 256 字节），max_count: 数组容量。
int ac_list_output_devices(char (*out_names)[256], int max_count);

// ==================== 工具 ====================

int ac_probe_sample_rate(const char* path);

#ifdef __cplusplus
}
#endif

#endif // WAVELINK_AUDIO_CORE_H
