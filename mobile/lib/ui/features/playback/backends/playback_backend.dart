/// 播放后端抽象：把「传输层」从播放器状态机中剥离出来。
///
/// 动机：DRM 的 Apple Music 曲目无法经 Rust 引擎解码，未来需接入
/// iOS MusicKit/AVPlayer 系统播放链路。届时新增一个 PlaybackBackend
/// 实现并按 SongSource 路由即可，播放器（PlayerNotifier）的队列/
/// 进度/断点/锁屏控制等状态机完全不用动。
///
/// 边界约定：接口只含各后端都有的传输原语（play/pause/resume/seek/
/// 位置/事件）；引擎专属能力（DSP、探测、遥测、ReplayGain、分析、
/// 封面提取）留在 AudioEngineRepository，由调用方按能力守卫使用。
abstract interface class PlaybackBackend {
  /// 后端是否可用（false 时播放器跳过所有传输调用）
  bool get available;

  /// 装载并播放本地文件路径
  Future<void> play(String path);
  Future<void> pause();
  Future<void> resume();

  /// seek 到指定秒数
  Future<void> seek(double posSecs);

  /// 当前播放位置（秒）。失败抛异常，调用方保留上次合法值
  Future<double> positionSecs();

  /// 轮询一条播放事件：'stopped'（曲终）/'error'/null（无事件）。
  /// 轮询型后端直接实现；未来流式后端可用 Stream 适配成单事件。
  Future<String?> pollEvents();

  /// 最近一次播放错误描述（配合 'error' 事件展示）
  Future<String> lastError();

  /// 后端是否正在出声
  Future<bool> isPlaying();

  /// 释放后端资源（播放器 dispose 时调用）
  Future<void> dispose();
}
