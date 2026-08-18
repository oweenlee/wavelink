/// WaveLink 桌面端引擎服务：封装 Rust FFI（Flutter Rust Bridge）桥接层。
///
/// 通过 `RustLib.init(externalLibrary:)` 加载 `desktop/rust` 编译出的动态库
/// （mac: libwavelink_desktop.dylib / win: wavelink_desktop.dll / linux:
/// libwavelink_desktop.so），调用由 flutter_rust_bridge 生成的 `wavelink*`
/// 函数，并把 Rust 的事件轮询模型转为 Dart `Stream<EngineEvent>`。
///
/// 绑定层与 mobile 统一（均经 flutter_rust_bridge 生成），命名与事件模型
/// 镜像 mobile 的 FRB 引擎，确保两端能力对齐。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path/path.dart' as p;

import '../src/rust/frb_generated.dart';
import '../src/rust/api/engine.dart' as frb;
import '../src/rust/api/smb.dart' as frb_smb;
import '../src/rust/api/webdav.dart' as frb_webdav;

/// 引擎事件（由 Rust 侧 JSON 反序列化而来）
class EngineEvent {
  const EngineEvent(this.type, [this.data = const {}]);

  /// 事件类型：track_changed / stopped / position / duration / error /
  /// queue_changed / spectrum / levels / dop_active
  final String type;
  final Map<String, dynamic> data;

  double? get value => data['value'] as double?;
  String? get path => data['path'] as String?;
  String? get message => data['message'] as String?;
  List<String>? get queue => (data['queue'] as List?)?.cast<String>();
  List<double>? get bands => (data['bands'] as List?)?.cast<double>();

  @override
  String toString() => 'EngineEvent($type, $data)';
}

/// 播放模式（与 Rust `PlayMode` 对齐）
enum PlayMode { normal, repeatOne, repeatAll, shuffle }

/// WaveLink 引擎（单例）。负责动态库加载、命令下发与事件轮询。
class Engine {
  Engine._();

  /// 初始化 RustLib 并加载动态库；找不到或加载失败返回 null
  /// （调用方应据此禁用播放并提示）。
  static Future<Engine?> load({String? dylibPath}) async {
    final path = dylibPath ?? _defaultDylibPath();
    debugPrint('[engine] resolved dylib path: $path');
    if (path == null) {
      debugPrint('[engine] 未找到 WaveLink 引擎动态库，播放不可用'
          '（请先 `cargo build -p wavelink_desktop`）');
      return null;
    }
    try {
      await RustLib.init(externalLibrary: ExternalLibrary.open(path));
      debugPrint('[engine] 动态库加载成功: $path');
    } catch (e) {
      debugPrint('[engine] 加载动态库失败: $e');
      return null;
    }
    return Engine._();
  }

  /// 候选动态库路径（按平台）。dev 默认指向 cargo 构建产物；打包后指向
  /// app bundle 内 Frameworks/ 目录（以可执行文件位置为锚点，避免 CWD 变化）。
  static String? _defaultDylibPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isMacOS) {
      final candidates = [
        p.join(exeDir, '../Frameworks/libwavelink_desktop.dylib'),
        p.join(exeDir, 'libwavelink_desktop.dylib'),
        'libwavelink_desktop.dylib',
        '../Frameworks/libwavelink_desktop.dylib',
        '../target/debug/libwavelink_desktop.dylib',
        '../target/release/libwavelink_desktop.dylib',
        'desktop/rust/target/debug/libwavelink_desktop.dylib',
        'desktop/rust/target/release/libwavelink_desktop.dylib',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
      return null;
    }
    if (Platform.isWindows) {
      final candidates = [
        p.join(exeDir, 'wavelink_desktop.dll'),
        'wavelink_desktop.dll',
        '..\\target\\debug\\wavelink_desktop.dll',
        '..\\target\\release\\wavelink_desktop.dll',
        'desktop/rust/target/debug/wavelink_desktop.dll',
        'desktop/rust/target/release/wavelink_desktop.dll',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
      return null;
    }
    if (Platform.isLinux) {
      final candidates = [
        p.join(exeDir, 'libwavelink_desktop.so'),
        'libwavelink_desktop.so',
        '../target/debug/libwavelink_desktop.so',
        '../target/release/libwavelink_desktop.so',
        'desktop/rust/target/debug/libwavelink_desktop.so',
        'desktop/rust/target/release/libwavelink_desktop.so',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
      return null;
    }
    return null;
  }

  bool _inited = false;
  Timer? _pollTimer;
  final _eventController = StreamController<EngineEvent>.broadcast();

  /// 引擎事件流（position / duration / track_changed / stopped / error ...）
  Stream<EngineEvent> get events => _eventController.stream;

  /// 初始化引擎。成功返回 null；失败返回错误字符串。
  Future<String?> initialize({
    int sampleRate = 44100,
    int channels = 2,
    int bufferMs = 280,
    bool bitPerfect = false,
    bool exclusiveMode = false,
    String? outputDevice,
  }) async {
    if (_inited) return null;
    final err = await frb.wavelinkInit(
      sampleRate: sampleRate,
      channels: channels,
      bufferMs: bufferMs,
      bitPerfect: bitPerfect,
      exclusiveMode: exclusiveMode,
      outputDevice: outputDevice,
    );
    if (err == null) {
      _inited = true;
      _startPolling();
    }
    return err;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (_eventController.isClosed) return;
      unawaited(_pollOnce());
    });
  }

  /// 单次轮询的事件吞吐上限：防止高频事件（spectrum/levels）生产快于消费
  /// 时 while 循环饿死 UI isolate。正常情况一次 poll 远达不到此数。
  static const _maxEventsPerPoll = 64;

  Future<void> _pollOnce() async {
    // 抽干本周期内积压的全部事件（Rust 侧每次只返回一个），
    // 否则事件泵吞吐被锁死在 ~25 事件/秒。
    for (var i = 0; i < _maxEventsPerPoll; i++) {
      final jsonStr = await frb.wavelinkPollEvent();
      if (jsonStr == null) return;
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        _eventController.add(EngineEvent(map['type'] as String, map));
      } catch (_) {
        // 忽略无法解析的事件
      }
    }
  }

  Future<void> play(String path) => frb.wavelinkPlay(path: path);

  /// 引擎侧整队列播放（Phase 2 gapless 预留，当前 UI 未接线：
  /// 桌面端队列/循环/随机由 PlayerController 在 Dart 侧管理，引擎逐曲播放）。
  Future<void> playQueue(List<String> paths, {int startIndex = 0}) async {
    final json = jsonEncode(paths);
    if (startIndex == 0) {
      await frb.wavelinkPlayQueueJson(json: json);
    } else {
      await frb.wavelinkPlayQueueAtJson(json: json, startIndex: startIndex);
    }
  }

  Future<void> pause() => frb.wavelinkPause();
  Future<void> resume() => frb.wavelinkResume();
  Future<void> stop() => frb.wavelinkStop();

  /// 引擎侧上/下一曲（Phase 2 gapless 预留，当前 UI 未接线，见 [playQueue]）。
  Future<void> next() => frb.wavelinkNext();
  Future<void> prev() => frb.wavelinkPrev();
  Future<void> seek(double posSecs) => frb.wavelinkSeek(posSecs: posSecs);
  Future<void> setVolume(double vol) => frb.wavelinkSetVolume(vol: vol);

  /// 引擎侧播放模式下发（Phase 2 预留，当前 UI 未接线，见 [playQueue]）。
  Future<void> setPlayMode(PlayMode mode) =>
      frb.wavelinkSetPlayMode(mode: mode.index); // 顺序与 Rust 约定一致

  /// 设置输出设备（Phase 2 设备选择 UI 预留，当前未接线）。
  Future<void> setOutputDevice(String? name) =>
      frb.wavelinkSetOutputDevice(name: name);

  Future<double> positionSecs() => frb.wavelinkPositionSecs();
  Future<double> durationSecs() => frb.wavelinkDurationSecs();
  Future<bool> isPlaying() => frb.wavelinkIsPlaying();
  Future<int> underrunCount() async =>
      (await frb.wavelinkUnderrunCount()).toInt();
  Future<String> currentPath() => frb.wavelinkCurrentPath();
  Future<String> lastError() => frb.wavelinkLastError();

  /// WebDAV 边下边播：Rust 从 [url] 分块拉取并喂入核心解码（首帧即出声），
  /// 同时写本地缓存。成功返回 null，失败返回错误字符串（由调用方回退下载）。
  ///
  /// [contentLength]：远端文件真实字节数（扫描期已知），作为流总长度传给
  /// 引擎，使 symphonia 算出真实时长 → 进度条准确。null 则引擎退化为粗估。
  /// [seekSecs]：流式 seek（拖进度条）时从该时间点重启流，null=从头播。
  Future<String?> playWebdavStream({
    required String url,
    required String username,
    required String password,
    String? formatHint,
    String? cacheFinalPath,
    int? contentLength,
    double? seekSecs,
  }) async {
    try {
      await frb_webdav.enginePlayWebdavStream(
        url: url,
        username: username,
        password: password,
        formatHint: formatHint,
        cacheFinalPath: cacheFinalPath,
        contentLength: contentLength == null ? null : BigInt.from(contentLength),
        seekSecs: seekSecs,
      );
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// NAS (SMB) 边下边播：Rust 从 [smbPath] 流式喂入核心解码并写缓存。
  /// 成功返回 null，失败返回错误字符串（由调用方回退全量下载）。
  ///
  /// [contentLength]：远端文件真实字节数（扫描期已知），同 WebDAV 用于进度准确。
  /// [seekSecs]：流式 seek（拖进度条）时从该时间点重启流，null=从头播。
  Future<String?> playSmbStream({
    required String smbPath,
    String? formatHint,
    String? cacheFinalPath,
    int? contentLength,
    double? seekSecs,
  }) async {
    try {
      await frb_smb.enginePlaySmbStream(
        smbPath: smbPath,
        formatHint: formatHint,
        cacheFinalPath: cacheFinalPath,
        contentLength: contentLength == null ? null : BigInt.from(contentLength),
        seekSecs: seekSecs,
      );
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// 枚举输出设备（Phase 2 设备选择 UI 预留，当前未接线）。
  Future<List<String>> enumerateDevices() => frb.wavelinkEnumerateDevices();

  void dispose() {
    _pollTimer?.cancel();
    if (!_eventController.isClosed) _eventController.close();
  }
}
