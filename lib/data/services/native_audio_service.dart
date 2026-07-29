import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
      debugPrint('[NativeAudio] 初始化事件通道失败: $e');
    }
    _initialized = true;
  }

  // ── 播放控制 ──

  Future<void> play() => _safeCall(_methodChannel.invokeMethod('play'));
  Future<void> pause() => _safeCall(_methodChannel.invokeMethod('pause'));
  Future<void> resume() => _safeCall(_methodChannel.invokeMethod('resume'));
  Future<void> stop() => _safeCall(_methodChannel.invokeMethod('stop'));

  // ── 锁屏信息更新 ──

  /// 更新锁屏显示的曲目元数据（含封面）
  /// [filePath] 传音频文件路径，iOS 原生提取封面图
  Future<void> updateMetadata({
    required String title,
    required String artist,
    String album = '',
    double duration = 0,
    String? filePath,
  }) =>
      _safeCall(_methodChannel.invokeMethod('updateMetadata', {
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'filePath': filePath ?? '',
      }));

  /// 更新锁屏显示播放进度
  Future<void> updatePosition(double positionMs) =>
      _safeCall(_methodChannel.invokeMethod('updatePosition', {
        'positionMs': positionMs,
      }));

  /// 切换 iOS 输出采样率（bit-perfect 协调）。
  /// 返回实际生效的采样率（setPreferredSampleRate 是请求非保证，内置输出常固定、外接 DAC 才会切）。
  /// 非 iOS 平台（无原生实现）返回 0。
  Future<double> setOutputRate(double rate) async {
    try {
      final result =
          await _methodChannel.invokeMethod<double>('setOutputRate', {'rate': rate});
      return result ?? 0.0;
    } on MissingPluginException {
      return 0.0;
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
