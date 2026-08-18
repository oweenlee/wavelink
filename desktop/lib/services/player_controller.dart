import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../models/playlist.dart';
import 'engine.dart';
import 'library.dart';
import 'lyrics.dart';
import 'nas_service.dart';
import 'subsonic_service.dart';
import 'webdav_service.dart';

/// Playback loop behaviour.
enum RepeatMode { off, all, one }

/// Central playback engine + library state.
///
/// 音频后端为 Rust `Engine`（经 FFI 桥接 `audio_core`），继承 hi-res / DSP /
/// bit-perfect 能力。播放顺序（队列 / 随机 / 循环）由本控制器在 Dart 侧管理，
/// 每首曲目通过 `engine.play(path)` 下发给引擎；曲目自然结束时由引擎的
/// `stopped` 事件驱动 `next()` 切歌（gapless / 引擎队列为 Phase 2）。
///
/// 收藏 / 播放列表 / 音量 / 模式经 shared_preferences 持久化；全部 UI 状态
/// 通过统一广播流暴露。
class PlayerController {
  Engine? _engine;
  String? _engineInitError;

  /// 引擎是否可播放（动态库已加载且初始化成功）。
  bool get engineReady => _engine != null && _engineInitError == null;

  /// 引擎初始化错误信息（null 表示成功或尚未加载）。
  String? get engineInitError => _engineInitError;

  /// prefs 实例缓存：init 时加载一次，之后所有持久化走缓存引用。
  /// 为 null（如单元测试未调 init）时持久化静默跳过，不影响内存状态。
  SharedPreferences? _prefs;

  /// 用户添加过的音乐文件夹（持久化，重启后重扫恢复曲库）。
  List<String> _folders = const [];

  List<Track> _library = const [];
  List<Track> _queue = const [];
  List<Track> _queueBase = const [];
  int? _queueIndex;

  final Set<String> _favoriteIds = {};
  List<Playlist> _playlists = const [];

  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;
  double _volume = 1.0;

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 用户主动停止标记：区分「自然结束」与「手动停止」，避免误触发切歌
  bool _stopRequested = false;

  final _positionSC = StreamController<Duration>.broadcast();
  final _durationSC = StreamController<Duration>.broadcast();
  final _playingSC = StreamController<bool>.broadcast();
  final _indexSC = StreamController<int?>.broadcast();
  final _lyricsSC = StreamController<List<LyricLine>>.broadcast();
  final _favoritesSC = StreamController<void>.broadcast();
  final _playlistsSC = StreamController<void>.broadcast();
  final _modeSC = StreamController<void>.broadcast();
  final _librarySC = StreamController<void>.broadcast();

  Stream<Duration> get positionStream => _positionSC.stream;
  Stream<Duration> get durationStream => _durationSC.stream;
  Stream<bool> get playingStream => _playingSC.stream;
  Stream<int?> get indexStream => _indexSC.stream;
  Stream<List<LyricLine>> get lyricsStream => _lyricsSC.stream;
  Stream<void> get favoritesStream => _favoritesSC.stream;
  Stream<void> get playlistsStream => _playlistsSC.stream;
  Stream<void> get modeStream => _modeSC.stream;

  /// 曲库内容变化（添加文件夹 / 启动重扫完成）。UI 订阅以替代 setState 刷新。
  Stream<void> get libraryStream => _librarySC.stream;

  List<Track> get library => _library;
  List<Playlist> get playlists => _playlists;
  Set<String> get favoriteIds => _favoriteIds;
  List<String> get folders => _folders;

  /// 当前播放队列（shuffle 开启时为打乱顺序）。
  List<Track> get queue => _queue;

  /// 基准队列（未打乱的原始顺序，shuffle 关闭时与 [queue] 相同）。
  List<Track> get queueBase => _queueBase;
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffle => _shuffle;
  double get volume => _volume;

  Track? get currentTrack =>
      (_queueIndex == null || _queue.isEmpty) ? null : _queue[_queueIndex!];
  int? get currentIndex => _queueIndex;
  bool get isPlaying => _playing;
  Duration get position => _position;
  Duration get duration => _duration;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _favoriteIds.addAll(_prefs!.getStringList('favorites') ?? []);
      final plJson = _prefs!.getStringList('playlists') ?? [];
      _playlists = plJson
          .map((e) => Playlist.fromJson(jsonDecode(e) as Map<String, dynamic>))
          .toList();
      _volume = (_prefs!.getDouble('volume') ?? 1.0).clamp(0.0, 1.0);
      final rm = _prefs!.getString('repeatMode');
      _repeatMode = RepeatMode.values.firstWhere(
        (e) => e.name == rm,
        orElse: () => RepeatMode.off,
      );
      _shuffle = _prefs!.getBool('shuffle') ?? false;
      _folders = _prefs!.getStringList('libraryFolders') ?? [];
    } catch (e) {
      debugPrint('prefs load error: $e');
    }

    // 恢复 Subsonic 会话凭据（WebDAV/NAS 凭据由 NetworkSourceConfig 直接读）。
    try {
      SubsonicService.loadFromPrefs();
    } catch (e) {
      debugPrint('subsonic prefs load error: $e');
    }

    // 加载 Rust 引擎（找不到 dylib 时为 null，播放不可用但 App 仍可启动）
    _engine = await Engine.load();
    _engineInitError = _engine == null
        ? null
        : await _engine!.initialize(
            sampleRate: 44100,
            channels: 2,
            bufferMs: 280,
          );
    if (_engineInitError != null) {
      debugPrint('engine init error: $_engineInitError');
    }
    _engine?.events.listen(_onEngineEvent);
    await _engine?.setVolume(_volume);

    // 恢复持久化的音乐文件夹（重扫，可能在 runApp 之后才完成——
    // UI 通过 libraryStream 感知曲库就绪）。
    if (_folders.isNotEmpty) {
      final restored = <Track>[];
      for (final folder in _folders) {
        restored.addAll(await scanFolder(folder));
      }
      addLibraryFiles(restored);
      _librarySC.add(null);
    }
  }

  void _onEngineEvent(EngineEvent e) {
    switch (e.type) {
      case 'position':
        if (e.value != null) {
          _position = Duration(milliseconds: (e.value! * 1000).round());
          _positionSC.add(_position);
        }
      case 'duration':
        if (e.value != null) {
          _duration = Duration(milliseconds: (e.value! * 1000).round());
          _durationSC.add(_duration);
        }
      case 'stopped':
        _playing = false;
        _playingSC.add(false);
        if (_stopRequested) {
          _stopRequested = false;
        } else {
          // 自然结束 → 切下一首（遵循循环/随机模式）
          next();
        }
      case 'error':
        debugPrint('engine error: ${e.message}');
      default:
        break;
    }
  }

  void setLibrary(List<Track> list) {
    _library = list;
    _queueBase = list;
    _queue = _shuffle ? _shuffled(list, null) : list;
    _queueIndex = null;
  }

  /// 向曲库累积添加一批曲目（按 id 去重）。
  /// 尚未开始播放时同步重建队列；正在播放时只更新曲库，不打断当前曲目。
  void addLibraryFiles(List<Track> tracks) {
    final map = <String, Track>{};
    for (final t in _library) {
      map[t.id] = t;
    }
    for (final t in tracks) {
      map[t.id] = t;
    }
    _library = map.values.toList();
    _queueBase = _library;
    if (_queueIndex == null) {
      _queue = _shuffle ? _shuffled(_library, null) : _library;
    }
  }

  /// 添加一个音乐文件夹：持久化路径 + 扫描并入曲库，并广播 libraryStream。
  /// 重复添加同一文件夹允许（等价于手动重扫，曲目按 id 去重）。
  Future<void> addFolder(String path) async {
    if (!_folders.contains(path)) {
      _folders = [..._folders, path];
      await _prefs?.setStringList('libraryFolders', _folders);
    }
    final tracks = await scanFolder(path);
    addLibraryFiles(tracks);
    _librarySC.add(null);
  }

  /// 移除一个音乐文件夹（曲库中该文件夹下的曲目一并移除）。
  Future<void> removeFolder(String path) async {
    _folders = _folders.where((f) => f != path).toList();
    await _prefs?.setStringList('libraryFolders', _folders);
    _library = _library
        .where((t) => !(t.filePath ?? '').startsWith('$path/'))
        .toList();
    _queueBase = _library;
    if (_queueIndex == null) {
      _queue = _shuffle ? _shuffled(_library, null) : _library;
    }
    _librarySC.add(null);
  }

  /// Resolve a playlist's ids into actual [Track] objects from the library.
  List<Track> tracksOfPlaylist(Playlist pl) =>
      _library.where((t) => pl.trackIds.contains(t.id)).toList();

  // ---- Network sources (WebDAV / NAS / Subsonic) -------------------------

  /// 扫描 WebDAV 服务器并导入曲库（按 id 去重）。返回扫描到的曲目。
  Future<List<Track>> importWebdav() async {
    final tracks = await WebdavService.scanWebdav();
    if (tracks.isNotEmpty) addLibraryFiles(tracks);
    _librarySC.add(null);
    return tracks;
  }

  /// 扫描 NAS (SMB) 共享并导入曲库。返回扫描到的曲目。
  Future<List<Track>> importNas() async {
    final tracks = await NasService.scan();
    if (tracks.isNotEmpty) addLibraryFiles(tracks);
    _librarySC.add(null);
    return tracks;
  }

  /// 扫描 Subsonic 音乐服务器并导入曲库。返回扫描到的曲目。
  Future<List<Track>> importSubsonic() async {
    final tracks = await SubsonicService.scanLibrary();
    if (tracks.isNotEmpty) addLibraryFiles(tracks);
    _librarySC.add(null);
    return tracks;
  }

  /// Begin playing [list] starting at [index], honoring shuffle state.
  void playFrom(List<Track> list, int index) {
    _queueBase = list;
    if (_shuffle) {
      _queue = _shuffled(list, index >= 0 && index < list.length
          ? list[index]
          : null);
      _queueIndex = 0;
    } else {
      _queue = list;
      _queueIndex = index;
    }
    if (_queueIndex != null) playIndex(_queueIndex!);
  }

  Future<void> playIndex(int index) async {
    if (index < 0 || index >= _queue.length) {
      debugPrint('[playIndex] index $index out of range (len=${_queue.length})');
      return;
    }
    _queueIndex = index;
    _indexSC.add(_queueIndex);
    _position = Duration.zero;
    _positionSC.add(_position);
    _duration = Duration.zero;
    _durationSC.add(_duration);

    final t = _queue[index];
    debugPrint('[playIndex] idx=$index source=${t.source.name} '
        'filePath=${t.filePath} remotePath=${t.remotePath}');
    // 网络扫描期已知的真实时长先填入，避免进度条先 0:00 再跳变。
    if (t.durationHint != null && t.durationHint! > Duration.zero) {
      _duration = t.durationHint!;
      _durationSC.add(_duration);
    }
    await _playTrack(t);
    _loadLyrics(t);
  }

  void _setPlaying(bool v) {
    _playing = v;
    _playingSC.add(v);
  }

  /// 按曲目来源分发播放：本地直播；WebDAV/NAS 走 Rust 边下边播，失败回退
  /// 全量下载；Subsonic 先下载流再本地播放。
  Future<void> _playTrack(Track t) async {
    if (_engine == null || _engineInitError != null) {
      debugPrint('[_playTrack] engine unavailable (null=$_engine, '
          'initError=$_engineInitError), cannot play ${t.id}');
      return;
    }
    switch (t.source) {
      case TrackSource.local:
        if (t.filePath != null) {
          try {
            await _engine!.play(t.filePath!);
            _setPlaying(true);
          } catch (e) {
            debugPrint('[_playTrack] engine.play failed: $e');
          }
        } else {
          debugPrint('[_playTrack] local track has no filePath: ${t.id}');
        }
      case TrackSource.webdav:
        await _playWebdav(t);
      case TrackSource.nas:
        await _playNas(t);
      case TrackSource.subsonic:
        await _playSubsonic(t);
    }
  }

  Future<void> _playWebdav(Track t) async {
    final davPath = t.remotePath;
    if (davPath == null) {
      debugPrint('[_playWebdav] remotePath null for ${t.id}');
      return;
    }
    final url = WebdavService.fullUrlFor(davPath);
    if (url == null) {
      debugPrint('[_playWebdav] fullUrl null for $davPath');
      return;
    }
    final cache = await WebdavService.cachePathFor(davPath);
    final err = await _engine!.playWebdavStream(
      url: url,
      username: WebdavService.username,
      password: WebdavService.password,
      formatHint: _formatHint(davPath),
      cacheFinalPath: cache,
      contentLength: t.fileSize,
    );
    if (err == null) {
      _setPlaying(true);
      return;
    }
    debugPrint('webdav 流式播放失败，回退下载: $err');
    final local = await WebdavService.downloadToLocal(davPath);
    if (local != null) {
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playWebdav] 回退下载失败: $davPath');
    }
  }

  Future<void> _playNas(Track t) async {
    final smbPath = t.remotePath;
    if (smbPath == null) {
      debugPrint('[_playNas] remotePath null for ${t.id}');
      return;
    }
    // 播放前确保 SMB 会话存活（扫描后可能已超时/断开）。
    final connErr = await NasService.connect();
    if (connErr != null) {
      debugPrint('[_playNas] connect failed: $connErr');
    }
    final cache = await NasService.cachePathFor(smbPath);
    final err = await _engine!.playSmbStream(
      smbPath: smbPath,
      formatHint: _formatHint(smbPath),
      cacheFinalPath: cache,
      contentLength: t.fileSize,
    );
    if (err == null) {
      _setPlaying(true);
      return;
    }
    debugPrint('nas 流式播放失败，回退下载: $err');
    final local = await NasService.downloadToLocal(t);
    if (local != null) {
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playNas] 回退下载失败: $smbPath');
    }
  }

  Future<void> _playSubsonic(Track t) async {
    final local = await SubsonicService.downloadStream(t);
    if (local != null) {
      await _engine!.play(local);
      _setPlaying(true);
    } else {
      debugPrint('[_playSubsonic] downloadStream failed for ${t.id}');
    }
  }

  /// 从路径取扩展名（不含点）作解码器提示。
  String? _formatHint(String? path) {
    if (path == null) return null;
    final ext = p.extension(path).toLowerCase();
    return ext.isEmpty ? null : ext.substring(1);
  }

  Future<void> _loadLyrics(Track t) async {
    final lines = await loadLyrics(t.lyricsPath);
    _lyricsSC.add(lines);
  }

  Future<void> togglePlay() async {
    if (_queueIndex == null) {
      if (_queue.isNotEmpty) await playIndex(0);
      return;
    }
    if (_playing) {
      await _engine?.pause();
      _playing = false;
      _playingSC.add(false);
    } else {
      await _engine?.resume();
      _playing = true;
      _playingSC.add(true);
    }
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    if (_queueIndex == null) {
      await playIndex(0);
      return;
    }
    if (_repeatMode == RepeatMode.one) {
      await playIndex(_queueIndex!);
      return;
    }
    final ni = _queueIndex! + 1;
    if (ni >= _queue.length) {
      if (_repeatMode == RepeatMode.all) {
        await playIndex(0);
      } else {
        _stopRequested = true;
        await _engine?.stop();
        _playing = false;
        _playingSC.add(false);
      }
    } else {
      await playIndex(ni);
    }
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (_queueIndex == null) {
      await playIndex(0);
      return;
    }
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final pi = _queueIndex! - 1;
    await playIndex(pi < 0 ? _queue.length - 1 : pi);
  }

  /// 曲目自然结束后的切歌由引擎 stopped 事件在 [_onEngineEvent] 中处理。
  Future<void> seek(Duration d) async {
    _position = d;
    _positionSC.add(d);
    // 用毫秒换算，保留亚秒精度（inSeconds 会截断到整秒）。
    await _engine?.seek(d.inMilliseconds / 1000.0);
  }

  /// Queue a track to play immediately after the current one.
  void playNext(Track t) {
    if (_queue.isEmpty) {
      _queueBase = [t];
      _queue = [t];
      _queueIndex = 0;
      playIndex(0);
      return;
    }
    // 插入播放队列：当前曲目之后。
    final at = (_queueIndex ?? -1) + 1;
    _queue = [..._queue.sublist(0, at), t, ..._queue.sublist(at)];
    // 插入基准队列：按当前曲目在 _queueBase 中的真实位置计算。
    // shuffle 模式下 _queue 与 _queueBase 顺序不同，不能复用队列下标。
    final baseAt = _queueBase.indexOf(currentTrack ?? t);
    final insertAt = baseAt < 0 ? _queueBase.length : baseAt + 1;
    _queueBase = [
      ..._queueBase.sublist(0, insertAt),
      t,
      ..._queueBase.sublist(insertAt),
    ];
    _indexSC.add(_queueIndex);
  }

  // ---- Favorites -----------------------------------------------------------

  bool isFavorite(Track t) => _favoriteIds.contains(t.id);

  Future<void> toggleFavorite(Track t) async {
    if (_favoriteIds.contains(t.id)) {
      _favoriteIds.remove(t.id);
    } else {
      _favoriteIds.add(t.id);
    }
    await _prefs?.setStringList('favorites', _favoriteIds.toList());
    _favoritesSC.add(null);
  }

  // ---- Playlists -----------------------------------------------------------

  Future<void> createPlaylist(String name) async {
    final pl = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '新建播放列表' : name.trim(),
    );
    _playlists = [..._playlists, pl];
    await _savePlaylists();
    _playlistsSC.add(null);
  }

  Future<void> deletePlaylist(String id) async {
    _playlists = _playlists.where((p) => p.id != id).toList();
    await _savePlaylists();
    _playlistsSC.add(null);
  }

  Future<void> addToPlaylist(String playlistId, String trackId) async {
    _playlists = _playlists.map((p) {
      if (p.id != playlistId || p.trackIds.contains(trackId)) return p;
      return p.copyWith(trackIds: [...p.trackIds, trackId]);
    }).toList();
    await _savePlaylists();
    _playlistsSC.add(null);
  }

  Future<void> _savePlaylists() async {
    await _prefs?.setStringList(
      'playlists',
      _playlists.map((p) => jsonEncode(p.toJson())).toList(),
    );
  }

  // ---- Modes & volume ------------------------------------------------------

  /// 只更新引擎音量（拖动过程中高频调用，不落盘）。
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    await _engine?.setVolume(_volume);
    _modeSC.add(null);
  }

  /// 持久化音量（拖动结束 onChangeEnd 时调用一次）。
  Future<void> persistVolume() async {
    await _prefs?.setDouble('volume', _volume);
  }

  Future<void> toggleShuffle() async {
    _shuffle = !_shuffle;
    final cur = currentTrack;
    if (_shuffle) {
      _queue = _shuffled(_queueBase, cur);
      _queueIndex = cur == null ? null : 0;
    } else {
      _queue = _queueBase;
      _queueIndex = cur == null ? null : _queueBase.indexOf(cur);
    }
    if (_queueIndex != null) _indexSC.add(_queueIndex);
    await _prefs?.setBool('shuffle', _shuffle);
    _modeSC.add(null);
  }

  Future<void> cycleRepeat() async {
    _repeatMode =
        RepeatMode.values[(_repeatMode.index + 1) % RepeatMode.values.length];
    await _prefs?.setString('repeatMode', _repeatMode.name);
    _modeSC.add(null);
  }

  List<Track> _shuffled(List<Track> list, Track? current) {
    final rest = list.where((t) => t != current).toList();
    rest.shuffle();
    return current == null ? rest : [current, ...rest];
  }

  Future<void> dispose() async {
    _engine?.dispose();
    await _positionSC.close();
    await _durationSC.close();
    await _playingSC.close();
    await _indexSC.close();
    await _lyricsSC.close();
    await _favoritesSC.close();
    await _playlistsSC.close();
    await _modeSC.close();
    await _librarySC.close();
  }
}
