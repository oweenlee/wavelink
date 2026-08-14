import 'dart:async';
import 'package:flutter/services.dart';
import 'log.dart';

/// iOS 音频输出 + 锁屏控制管理器
/// 实际音频数据走 Rust ringbuf → AVAudioSourceNode 直出，
/// Flutter 发控制命令（play/pause/stop）和更新锁屏信息
class NativeAudioService {
  static const _methodChannel = MethodChannel('wavelink/audio');
  static const _eventChannel = EventChannel('wavelink/audio_events');

  final StreamController<AudioEvent> _eventController =
      StreamController<AudioEvent>.broadcast();
  StreamSubscription? _sub;
  bool _initialized = false;

  Stream<AudioEvent> get events => _eventController.stream;

  Future<void> init() async {
    if (_initialized) return;
    try {
      _sub = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (data == 'completed') {
            _eventController.add(const AudioCompleted());
          } else if (data is String && data.startsWith('error:')) {
            _eventController.add(AudioError(data.substring(6)));
          } else if (data is String && data.startsWith('remote:')) {
            final parts = data.substring(7).split(':');
            final cmd = parts[0];
            final arg = parts.length > 1 ? double.tryParse(parts[1]) : null;
            _eventController.add(RemoteCommand(cmd, arg));
          }
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (e) {
      Log.e('NativeAudio', '初始化事件通道失败: $e');
    }
    _initialized = true;
  }

  // ── 播放控制 ──

  /// Android 以指定采样率/声道启动流式播放（iOS 忽略参数）
  Future<void> play({int sampleRate = 44100, int channels = 2}) => _safeCall(
    _methodChannel.invokeMethod('play', {
      'sampleRate': sampleRate,
      'channels': channels,
    }),
  );
  Future<void> pause() => _safeCall(_methodChannel.invokeMethod('pause'));
  Future<void> resume() => _safeCall(_methodChannel.invokeMethod('resume'));
  Future<void> stop() => _safeCall(_methodChannel.invokeMethod('stop'));

  /// Android seek：清掉 pcmQueue/AudioTrack 里 seek 前的旧 PCM（iOS 无此通道，静默）。
  /// 必须在引擎 seek 之后调：引擎先换新 ringbuf，原生再 flush 旧缓冲。
  Future<void> seek(double positionMs) => _safeCall(
    _methodChannel.invokeMethod('seek', {'positionMs': positionMs}),
  );

  // ── 锁屏信息更新 ──

  /// 更新锁屏显示的曲目元数据（含封面）
  /// [coverPath] 优先：Dart 侧已提取的封面图片文件（jpg），原生直接读图
  /// [filePath] 兼容回退：音频文件路径，原生提取内嵌封面
  Future<void> updateMetadata({
    required String title,
    required String artist,
    String album = '',
    double duration = 0,
    String? filePath,
    String? coverPath,
  }) => _safeCall(
    _methodChannel.invokeMethod('updateMetadata', {
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'filePath': filePath ?? '',
      'coverPath': coverPath ?? '',
    }),
  );

  /// 更新锁屏显示播放进度
  Future<void> updatePosition(double positionMs) => _safeCall(
    _methodChannel.invokeMethod('updatePosition', {'positionMs': positionMs}),
  );

  /// 幂等状态对账：只同步锁屏按钮态（iOS PlaybackRate / Android
  /// PlaybackState），不动音频门控、不重启 engine。供 Dart 周期性把
  /// 权威状态推给原生——偶发的通道调用丢失/延迟可在下个对账周期自愈。
  Future<void> syncPlaying(bool isPlaying) => _safeCall(
    _methodChannel.invokeMethod('syncPlaying', {'isPlaying': isPlaying}),
  );

  // ── 歌词行展示（Android 媒体通知展开视图）──

  /// 推送当前歌词行到原生层：更新 Android 媒体通知展开视图的歌词行。
  /// 仅当前行文本变化时调用（Dart 侧去抖，避免 250ms tick 反复打通道）。
  Future<void> updateLiveLyrics({
    required String title,
    required String artist,
    required String lyricLine,
    required bool isPlaying,
  }) => _safeCall(
    _methodChannel.invokeMethod('updateLiveLyrics', {
      'title': title,
      'artist': artist,
      'lyricLine': lyricLine,
      'isPlaying': isPlaying,
    }),
  );

  /// 结束歌词展示（Android 清空媒体通知歌词行）。
  Future<void> endLiveLyrics() => _safeCall(
    _methodChannel.invokeMethod('endLiveLyrics'),
  );

  /// 查询 Android 设备原生输出采样率（AudioTrack.getNativeOutputSampleRate）。
  /// iOS 无此通道实现（MissingPluginException）→ 返回 0。
  Future<int> getNativeOutputRate() async {
    try {
      final rate = await _methodChannel.invokeMethod<int>('getNativeRate');
      return rate ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// 切换 iOS 输出采样率（bit-perfect 协调）。
  /// 返回实际生效的采样率（setPreferredSampleRate 是请求非保证，内置输出常固定、外接 DAC 才会切）。
  /// 非 iOS 平台（无原生实现）返回 0。
  Future<double> setOutputRate(double rate) async {
    try {
      final result = await _methodChannel.invokeMethod<double>(
        'setOutputRate',
        {'rate': rate},
      );
      return result ?? 0.0;
    } on MissingPluginException {
      return 0.0;
    }
  }

  /// iOS：把 iPod library 歌曲（ipod-library:// URL）导出为本地文件，
  /// 返回可被 Rust 解码的绝对路径；失败返回 null（非 iOS 平台恒 null）。
  Future<String?> resolveLibraryAsset(String url) async {
    try {
      return await _methodChannel.invokeMethod<String>(
        'resolveLibraryAsset',
        {'url': url},
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _safeCall(Future<void> call) async {
    try {
      await call;
    } on MissingPluginException {
      // 无原生实现时静默（macOS）
    }
  }

  void dispose() {
    _sub?.cancel();
    _eventController.close();
  }
}

// ── 事件类型 ──

sealed class AudioEvent {
  const AudioEvent();
}

class AudioCompleted extends AudioEvent {
  const AudioCompleted();
}

class AudioError extends AudioEvent {
  final String message;
  const AudioError(this.message);
}

/// 锁屏/控制中心远程命令
class RemoteCommand extends AudioEvent {
  final String command;

  /// seek 时的目标位置（秒），仅 command 为 "seek" 时有值
  final double? seekPosition;
  const RemoteCommand(this.command, [this.seekPosition]);
}
