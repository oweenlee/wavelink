import 'dart:async';
import 'package:flutter/services.dart';

/// iOS 音频输出管理器
/// 实际音频数据走 Rust ringbuf → AVAudioSourceNode 直出，
/// Flutter 只发控制命令（play/pause/stop）和接收事件
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
            _eventController.add(AudioError(data));
          }
        },
        onError: (_) {
          // macOS：无原生事件通道
        },
        cancelOnError: false,
      );
    } catch (_) {
      // macOS：receiveBroadcastStream 同步抛 MissingPluginException
    }
    _initialized = true;
  }

  Future<void> play() => _safeCall(_methodChannel.invokeMethod('play'));
  Future<void> pause() => _safeCall(_methodChannel.invokeMethod('pause'));
  Future<void> resume() => _safeCall(_methodChannel.invokeMethod('resume'));
  Future<void> stop() => _safeCall(_methodChannel.invokeMethod('stop'));

  Future<void> _safeCall(Future<void> call) async {
    try {
      await call;
    } on MissingPluginException {
      // 无原生实现时静默
    }
  }

  void dispose() {
    _sub?.cancel();
    _eventController.close();
  }
}

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
