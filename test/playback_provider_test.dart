import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wavelink_mobile/models/song.dart';
import 'package:wavelink_mobile/providers/playback_provider.dart';
import 'package:wavelink_mobile/services/preferences_service.dart';

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

  PlaybackProvider buildProvider({bool autoPlay = false}) {
    final p = PlaybackProvider();
    p.autoPlayOnQueueSet = autoPlay;
    // 注入测试歌曲，绕过 Documents 扫描结果
    p.setQueue([
      _song('s1', title: 'A'),
      _song('s2', title: 'B'),
      _song('s3', title: 'C'),
    ]);
    return p;
  }

  group('PlaybackProvider 队列逻辑', () {
    test('setQueue 设置队列并重置索引', () {
      final p = buildProvider();
      expect(p.queue.length, 3);
      expect(p.currentIndex, 0);
      expect(p.currentSong?.id, 's1');
    });

    test('next 顺序播放与循环边界', () {
      final p = buildProvider();
      p.next();
      expect(p.currentIndex, 1);
      p.next();
      p.next();
      expect(p.currentIndex, 0); // 回到开头
    });

    test('previous 在开头回绕', () {
      final p = buildProvider();
      p.previous();
      expect(p.currentIndex, 2);
    });

    test('single 循环模式重复当前曲', () {
      final p = buildProvider();
      p.toggleLoopMode(); // list -> single
      expect(p.loopMode, LoopMode.single);
      p.next();
      expect(p.currentIndex, 0);
    });

    test('shuffle 模式 random next 不越界', () {
      final p = buildProvider();
      p.toggleShuffle();
      p.next();
      expect(p.currentIndex >= 0 && p.currentIndex <= 2, isTrue);
    });

    test('playSong 按 id 定位', () {
      final p = buildProvider();
      p.playSong(_song('s3'));
      expect(p.currentIndex, 2);
    });

    test('addToQueue / playNext 插入', () {
      final p = buildProvider();
      p.addToQueue(_song('sX'));
      expect(p.queue.length, 4);
      p.playNext(_song('sY'));
      // 插入到 currentIndex+1
      expect(p.queue[p.currentIndex + 1].id, 'sY');
    });

    test('removeFromQueue 当前项后自动前进', () {
      final p = buildProvider();
      p.next(); // index=1
      p.removeFromQueue(1);
      expect(p.queue.length, 2);
      expect(p.currentIndex, 0);
    });

    test('reorderQueue 移动元素', () {
      final p = buildProvider();
      p.reorderQueue(0, 2); // 末尾前移：s1 移到 index 1
      expect(p.queue[1].id, 's1');
    });
  });

  group('PlaybackProvider 收藏与偏好', () {
    test('toggleFavorite 增删并持久化', () async {
      final p = buildProvider();
      expect(p.isSongFavorite('s1'), isFalse);
      p.toggleFavorite(); // 收藏当前 s1
      expect(p.isSongFavorite('s1'), isTrue);
      expect(p.favoriteSongs.any((s) => s.id == 's1'), isTrue);
      p.toggleFavorite();
      expect(p.isSongFavorite('s1'), isFalse);
    });

    test('setFavorite 显式设置', () {
      final p = buildProvider();
      p.setFavorite('s2', true);
      expect(p.isSongFavorite('s2'), isTrue);
      p.setFavorite('s2', false);
      expect(p.isSongFavorite('s2'), isFalse);
    });

    test('setVolume 夹紧范围并持久化', () async {
      final p = buildProvider();
      p.setVolume(2.0);
      expect(p.volume, 1.0);
      p.setVolume(-1);
      expect(p.volume, 0.0);
      expect(PreferencesService.instance.volume, 0.0);
    });

    test('toggleLoopMode 循环三态', () {
      final p = buildProvider();
      expect(p.loopMode, LoopMode.list);
      p.toggleLoopMode();
      p.toggleLoopMode();
      expect(p.loopMode, LoopMode.shuffle);
      expect(PreferencesService.instance.loopMode, 'shuffle');
    });

    test('DSP toggle 持久化', () async {
      final p = buildProvider();
      expect(p.dspSettings.crossfeed, isFalse);
      p.toggleCrossfeed();
      expect(p.dspSettings.crossfeed, isTrue);
      expect(PreferencesService.instance.dspCrossfeed, isTrue);
    });
  });

  group('PlaybackProvider 播放列表', () {
    test('saveCurrentQueueAsPlaylist 后可读出', () async {
      final p = buildProvider();
      await p.saveCurrentQueueAsPlaylist('测试列表');
      final songs = p.playlistSongs('测试列表');
      expect(songs.length, 3);
      expect(songs.first.id, 's1');
    });
  });

  group('PlaybackProvider 解码/播放时序（刺啦修复回归）', () {
    test('play 必须等解码器启动完成后再调用，避免空 ringbuf 爆音', () async {
      final audioCalls = <String>[];
      var stopResolved = false;
      final stopCompleter = Completer<void>();

      // 先建 provider（autoPlay=false，setQueue 不自动播放，避免副作用污染）
      final p = buildProvider(autoPlay: false);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('wavelink/audio'),
        (call) async {
          audioCalls.add(call.method);
          if (call.method == 'stop') {
            // 模拟旧解码器停止有延迟
            await stopCompleter.future;
            stopResolved = true;
            return null;
          }
          return null;
        },
      );

      // 注入一个“慢解码器”钩子：必须在 stop 完成后才 resolve
      final decoderStarted = Completer<void>();
      p.startDecoderHook = (_) async {
        // 等 stop 真正完成
        await stopCompleter.future;
        decoderStarted.complete();
      };

      // 触发播放（内部 _playCurrent 会 fire-and-forget）
      p.play();

      // 给 Flutter 事件循环一点时间去执行 _playCurrent 的同步部分
      await Future.delayed(const Duration(milliseconds: 50));

      // 此时 stop 已被调用但还没 resolve，play 绝不应先于解码器启动
      expect(audioCalls.contains('play'), isFalse,
          reason: '解码器未就绪前不应调用 play()');

      // 让 stop / 解码器依次完成
      stopCompleter.complete();
      await decoderStarted.future;
      // 等待 _playCurrent 的 .then 链跑完（play 在解码器就绪后才调用）
      await Future.delayed(const Duration(milliseconds: 50));

      expect(stopResolved, isTrue);
      expect(audioCalls, contains('play'),
          reason: '解码器就绪后应调用 play() 恢复输出');
      // 关键断言：play 的出现位置必须在最后一次 stop 之后
      final lastStop = audioCalls.lastIndexOf('stop');
      final firstPlay = audioCalls.indexOf('play');
      expect(firstPlay, greaterThan(lastStop),
          reason: 'play() 必须在 stop() 之后调用，不能在切换窗口期抢跑');
    });

    test('切歌竞态：上一首未结束不应让 play 抢跑', () async {
      final audioCalls = <String>[];
      // 先建 provider（autoPlay=false，setQueue 不自动播放，避免副作用污染）
      final p = buildProvider(autoPlay: false);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('wavelink/audio'),
        (call) async {
          audioCalls.add(call.method);
          return null;
        },
      );

      // 第一首
      p.play();
      await Future.delayed(const Duration(milliseconds: 30));
      // 立即切到第二首（模拟快速切歌）
      p.next();
      await Future.delayed(const Duration(milliseconds: 30));

      // 序列应以 stop 开头、以 play 结尾，且最后一个 play 之后不应再出现 stop
      //（即不会在播放中突然清空 ringbuf 造成爆音）
      expect(audioCalls.first, 'stop');
      expect(audioCalls.last, 'play');
      final lastPlay = audioCalls.lastIndexOf('play');
      final stopsAfterPlay = audioCalls
          .sublist(lastPlay + 1)
          .where((m) => m == 'stop')
          .length;
      expect(stopsAfterPlay, 0,
          reason: '最后一个 play() 之后不应再出现 stop（不会在播放中突然清空）');
    });
  });
}
