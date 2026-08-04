#import "GeneratedPluginRegistrant.h"

// Rust ringbuf 填充函数（audio_output.rs 中 #[no_mangle] 导出）
// 非交错格式：left/right 分别指向左右声道 buffer
void audio_output_fill_buffer_stereo(float * _Nonnull left, float * _Nonnull right, unsigned int frames);

// 清空 ringbuf 残留（暂停恢复时丢弃积压数据，避免磁带滑）
void audio_output_clear_ringbuf(void);

// 播放门控（play/pause/resume/stop 时设置；渲染回调无锁读取，false 时输出静音）
void audio_output_set_playing(bool playing);

// 设置硬件采样率（从 AVAudioSession 获取后传入 Rust）
void set_hw_sample_rate(unsigned int rate);

// 系统运行时改变硬件采样率时，把引擎输出速率对齐到新速率（与重建 source node 配套）
void engine_sync_output_rate(unsigned int rate);
