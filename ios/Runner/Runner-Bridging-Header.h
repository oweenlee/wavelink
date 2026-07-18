#import "GeneratedPluginRegistrant.h"

// Rust ringbuf 填充函数（audio_output.rs 中 #[no_mangle] 导出）
// 非交错格式：left/right 分别指向左右声道 buffer
void audio_output_fill_buffer_stereo(float * _Nonnull left, float * _Nonnull right, unsigned int frames);
