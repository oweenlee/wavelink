import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/domain/models/song.dart';
import 'package:wavelink_mobile/ui/features/playback/view_models/playback_controller.dart';
import 'package:wavelink_mobile/ui/core/providers/repositories.dart';
import 'package:wavelink_mobile/data/services/preferences_service.dart';
import 'helpers/mock_repositories.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:checks/checks.dart';

Song _song(String id, {String title = '', String artist = ''}) => Song(
  id: id,
  title: title.isEmpty ? id : title,
  artist: artist,
  album: 'album',
  duration: const Duration(seconds: 100),
  dominantColor: const Color(0xFF000000),
  path: '/tmp/$id.flac',
);

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.init();
    // 屏蔽 path_provider / MethodChannel 的原生调用
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
  });

  PlaybackController buildProvider({bool autoPlay = false}) {
    final container = ProviderContainer(
      overrides: [
        audioEngineRepositoryProvider.overrideWith(
          (_) => MockAudioEngineRepository(),
        ),
        songRepositoryProvider.overrideWith((_) => MockSongRepository()),
        preferencesRepositoryProvider.overrideWith(
          (_) => PreferencesRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final p = container.read(playbackControllerProvider);
    // 与旧 PlaybackProvider 构造行为对齐：触发偏好加载/引擎 init/扫描
    p.bootstrap();
    p.autoPlayOnQueueSet = autoPlay;
    // 注入测试歌曲，绕过 Documents 扫描结果
    p.setQueue([
      _song('s1', title: 'A'),
      _song('s2', title: 'B'),
      _song('s3', title: 'C'),
    ]);
    return p;
  }

  group('PlaybackController 队列逻辑', () {
    test('setQueue 设置队列并重置索引', () {
      final p = buildProvider();
      check(p.queue.length).equals(3);
      check(p.currentIndex).equals(0);
      check(p.currentSong?.id).equals('s1');
    });

    test('setQueue 空队列不崩溃且索引归零（clamp 回归）', () {
      final p = buildProvider();
      p.setQueue([]);
      check(p.queue.length).equals(0);
      check(p.currentIndex).equals(0);
      check(p.currentSong).isNull();
    });

    test('next 顺序播放与循环边界', () {
      final p = buildProvider();
      p.next();
      check(p.currentIndex).equals(1);
      p.next();
      p.next();
      check(p.currentIndex).equals(0); // 回到开头
    });

    test('previous 在开头回绕', () {
      final p = buildProvider();
      p.previous();
      check(p.currentIndex).equals(2);
    });

    test('single 循环模式重复当前曲', () {
      final p = buildProvider();
      p.toggleLoopMode(); // list -> single
      check(p.loopMode).equals(LoopMode.single);
      p.next();
      check(p.currentIndex).equals(0);
    });

    test('shuffle 模式 random next 不越界', () {
      final p = buildProvider();
      p.setLoopMode(LoopMode.shuffle);
      p.next();
      check(p.currentIndex >= 0 && p.currentIndex <= 2).isTrue();
    });

    test('shuffle 模式单曲队列 next 不崩溃', () {
      final p = buildProvider();
      p.setQueue([_song('solo')]);
      p.setLoopMode(LoopMode.shuffle);
      p.next();
      check(p.currentIndex).equals(0);
    });

    test('findNextIndex 队列单曲不崩溃', () {
      final p = buildProvider();
      p.setQueue([_song('solo')]);
      p.setLoopMode(LoopMode.shuffle);
      check(p.findNextIndex()).equals(0);
    });

    test('playSong 按 id 定位', () {
      final p = buildProvider();
      p.playSong(_song('s3'));
      check(p.currentIndex).equals(2);
    });

    test('addToQueue / playNext 插入', () {
      final p = buildProvider();
      p.addToQueue(_song('sX'));
      check(p.queue.length).equals(4);
      p.playNext(_song('sY'));
      // 插入到 currentIndex+1
      check(p.queue[p.currentIndex + 1].id).equals('sY');
    });

    test('removeFromQueue 当前项后自动前进', () {
      final p = buildProvider();
      p.next(); // index=1 (s2)
      p.removeFromQueue(1); // 移除当前项 s2，队列变 [s1,s3]，自动前进到 s3
      check(p.queue.length).equals(2);
      check(p.currentIndex).equals(1); // 前进到 s3（新 index 1），而非倒退到 s1
      check(p.currentSong?.id).equals('s3');
    });

    test('reorderQueue 移动元素', () {
      final p = buildProvider();
      p.reorderQueue(0, 2); // 末尾前移：s1 移到 index 1
      check(p.queue[1].id).equals('s1');
    });
  });

  group('PlaybackController 收藏与偏好', () {
    test('toggleFavorite 增删并持久化', () async {
      final p = buildProvider();
      check(p.isSongFavorite('s1')).isFalse();
      p.toggleFavorite(); // 收藏当前 s1
      check(p.isSongFavorite('s1')).isTrue();
      check(p.favoriteSongs.any((s) => s.id == 's1')).isTrue();
      p.toggleFavorite();
      check(p.isSongFavorite('s1')).isFalse();
    });

    test('setFavorite 显式设置', () {
      final p = buildProvider();
      p.setFavorite('s2', true);
      check(p.isSongFavorite('s2')).isTrue();
      p.setFavorite('s2', false);
      check(p.isSongFavorite('s2')).isFalse();
    });

    test('setVolume 夹紧范围并持久化', () async {
      final p = buildProvider();
      p.setVolume(2.0);
      check(p.volume).equals(1.0);
      p.setVolume(-1);
      check(p.volume).equals(0.0);
      check(PreferencesService.instance.volume).equals(0.0);
    });

    test('toggleLoopMode 循环三态', () {
      final p = buildProvider();
      check(p.loopMode).equals(LoopMode.list);
      p.toggleLoopMode();
      p.toggleLoopMode();
      check(p.loopMode).equals(LoopMode.shuffle);
      check(PreferencesService.instance.loopMode).equals('shuffle');
    });

    test('DSP toggle 持久化', () async {
      final p = buildProvider();
      check(p.dspSettings.crossfeed).isFalse();
      p.toggleCrossfeed();
      check(p.dspSettings.crossfeed).isTrue();
      check(PreferencesService.instance.dspCrossfeed).isTrue();
    });
  });

  group('PlaybackController 播放列表', () {
    test('saveCurrentQueueAsPlaylist 后可读出', () async {
      final p = buildProvider();
      await p.saveCurrentQueueAsPlaylist('测试列表');
      final songs = p.playlistSongs('测试列表');
      check(songs.length).equals(3);
      check(songs.first.id).equals('s1');
    });
  });

  group('PlaybackController 解码/播放时序（刺啦修复回归）', () {
    // 注：audio-core 迁移（b26c796）后，旧的显式防爆音流程（stopDecoder/startDecoder/
    // _waitFirstFrame/_bufferRingbuf + startDecoderHook）已移除，改由引擎内部管理解码。
    // 当前架构保留的时序保证是：native play 必在 native stop 完成之后（_playCurrent 中
    // await stop() → await engine.play() → native.play()）。以下用例验证该时序；
    // 真正的空 ringbuf 防爆音效果需 iOS 真机验证（依赖 audio-core 内部缓冲）。
    test('native play 必须等 stop 完成后再调用，避免空 ringbuf 爆音', () async {
      final audioCalls = <String>[];
      var stopResolved = false;
      final stopCompleter = Completer<void>();

      // 先建 provider（autoPlay=false，setQueue 不自动播放，避免副作用污染）
      final p = buildProvider(autoPlay: false);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('wavelink/audio'), (
            call,
          ) async {
            audioCalls.add(call.method);
            if (call.method == 'stop') {
              // 模拟 stop 有延迟
              await stopCompleter.future;
              stopResolved = true;
              return null;
            }
            return null;
          });

      // 触发播放（内部 _playCurrent 会 fire-and-forget）
      p.play();

      // 给 Flutter 事件循环一点时间去执行 _playCurrent 的同步部分
      await Future.delayed(const Duration(milliseconds: 50));

      // 此时 stop 已被调用但还没 resolve，play 绝不应先于 stop 完成
      check(audioCalls.contains('play')).isFalse();

      // 让 stop 完成
      stopCompleter.complete();
      // 等待 _playCurrent 的 .then 链跑完（play 在 stop 就绪后才调用）
      await Future.delayed(const Duration(milliseconds: 50));

      check(stopResolved).isTrue();
      check(audioCalls).contains('play');
      // 关键断言：play 的出现位置必须在最后一次 stop 之后
      final lastStop = audioCalls.lastIndexOf('stop');
      final firstPlay = audioCalls.indexOf('play');
      check(firstPlay).isGreaterThan(lastStop);
    });

    test('切歌竞态：上一首未结束不应让 play 抢跑', () async {
      final audioCalls = <String>[];
      // 先建 provider（autoPlay=false，setQueue 不自动播放，避免副作用污染）
      final p = buildProvider(autoPlay: false);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('wavelink/audio'), (
            call,
          ) async {
            audioCalls.add(call.method);
            return null;
          });

      // 第一首
      p.play();
      await Future.delayed(const Duration(milliseconds: 30));
      // 立即切到第二首（模拟快速切歌）
      p.next();
      await Future.delayed(const Duration(milliseconds: 30));

      // 序列应以 stop 开头、以 play 结尾，且最后一个 play 之后不应再出现 stop
      //（即不会在播放中突然清空 ringbuf 造成爆音）
      // 只考察影响 ringbuf 的 stop/play，忽略 updatePosition/updateMetadata 等无害调用
      final sp = audioCalls
          .where((m) => m == 'stop' || m == 'play')
          .toList();
      check(sp.first).equals('stop');
      check(sp.last).equals('play');
      final lastPlay = sp.lastIndexOf('play');
      final stopsAfterPlay = sp
          .sublist(lastPlay + 1)
          .where((m) => m == 'stop')
          .length;
      check(stopsAfterPlay).equals(0);
    });
  });

  group('断点续播', () {
    /// 构造带 mock override 的容器（与 buildProvider 相同注入，但暴露 container）。
    /// [bootstrap] 为 false 时由调用方先注入曲库再手动 bootstrap（避免 async 方法体
    /// 同步执行导致 Future 固定为空列表的问题）。
    (ProviderContainer, PlaybackController) buildContainer({bool bootstrap = true}) {
      final container = ProviderContainer(
        overrides: [
          audioEngineRepositoryProvider.overrideWith(
            (_) => MockAudioEngineRepository(),
          ),
          songRepositoryProvider.overrideWith((_) => MockSongRepository()),
          preferencesRepositoryProvider.overrideWith(
            (_) => PreferencesRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final p = container.read(playbackControllerProvider);
      if (bootstrap) p.bootstrap();
      return (container, p);
    }

    test('保存断点：播放中暂停写入队列/索引/位置', () async {
      final (_, p) = buildContainer();
      await Future<void>.delayed(const Duration(milliseconds: 30)); // 等空库扫描完成
      p.setQueue([_song('s1'), _song('s2'), _song('s3')]);
      p.play();
      await Future<void>.delayed(const Duration(milliseconds: 30)); // 等装载完成
      p.seek(0.5, immediate: true); // 100s * 0.5 = 50s
      p.pause();
      // saveResume 是 fire-and-forget 异步写盘，等其完成（最多丢 5s 兜底，测试里直接等）
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final prefs = PreferencesRepository();
      check(prefs.resumeQueue).deepEquals(['s1', 's2', 's3']);
      check(prefs.resumeIndex).equals(0);
      check(prefs.resumePositionMs).isCloseTo(50000, 1);
    });

    test('恢复断点：曲库就绪后恢复队列/索引/位置，不自动播放', () async {
      final prefs = PreferencesRepository();
      await prefs.setResume(
        queueIds: ['s2', 's3'],
        index: 1,
        positionMs: 30000,
      );

      final (container, p) = buildContainer(bootstrap: false);
      (container.read(songRepositoryProvider) as MockSongRepository)
          .songsToReturn = [_song('s1'), _song('s2'), _song('s3')];
      p.bootstrap();
      await Future<void>.delayed(const Duration(milliseconds: 30)); // 等扫描+恢复

      check(p.queue.map((s) => s.id).toList()).deepEquals(['s2', 's3']);
      check(p.currentIndex).equals(1);
      check(p.currentSong?.id).equals('s3');
      check(p.position).isCloseTo(30000, 1);
      check(p.isPlaying).isFalse(); // 不自动播放
    });

    test('恢复断点后播放：完整装载并从保存位置继续', () async {
      final prefs = PreferencesRepository();
      await prefs.setResume(queueIds: ['s1'], index: 0, positionMs: 42000);

      // 引擎可用版 mock：让 play/seek 真正走到引擎仓库（默认 mock rustAvailable=false）
      final engine = _EngineAvailableMock();
      final container = ProviderContainer(
        overrides: [
          audioEngineRepositoryProvider.overrideWith((_) => engine),
          songRepositoryProvider.overrideWith((_) => MockSongRepository()),
          preferencesRepositoryProvider.overrideWith(
            (_) => PreferencesRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);
      // _playCurrent 会校验本地文件存在性，需真实创建
      File('/tmp/s1.flac').writeAsBytesSync([0, 1, 2, 3]);
      (container.read(songRepositoryProvider) as MockSongRepository)
          .songsToReturn = [_song('s1')];
      final p = container.read(playbackControllerProvider);
      p.bootstrap();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 恢复后未播放：位置已就位，引擎未装载
      check(p.currentSong?.id).equals('s1');
      check(p.position).isCloseTo(42000, 1);
      check(p.isPlaying).isFalse();

      p.play();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      check(engine.playCalls.length).equals(1); // 走完整装载而非空 resume
      check(engine.position).isCloseTo(42.0, 0.1); // seek 到保存位置（秒）
      check(p.isPlaying).isTrue();
    });
  });
}

/// 引擎可用版 mock：默认 mock 的 rustAvailable=false 会跳过 play/seek 调用，
/// 断点续播的「装载+seek」链路需要引擎仓库真正可用才能断言。
class _EngineAvailableMock extends MockAudioEngineRepository {
  @override
  bool get rustAvailable => true;
}
