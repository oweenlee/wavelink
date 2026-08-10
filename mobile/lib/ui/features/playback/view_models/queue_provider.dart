import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math' as math;
import '../../../../domain/models/song.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../core/providers/repositories.dart';

class QueueState {
  final List<Song> queue;
  final int currentIndex;
  final LoopMode loopMode;
  final bool shuffle;

  const QueueState({
    this.queue = const [],
    this.currentIndex = 0,
    this.loopMode = LoopMode.list,
    this.shuffle = false,
  });

  bool get hasSong => queue.isNotEmpty;
  Song? get currentSong => queue.isNotEmpty ? queue[currentIndex] : null;

  QueueState copyWith({
    List<Song>? queue,
    int? currentIndex,
    LoopMode? loopMode,
    bool? shuffle,
  }) {
    return QueueState(
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      loopMode: loopMode ?? this.loopMode,
      shuffle: shuffle ?? this.shuffle,
    );
  }
}

class QueueNotifier extends Notifier<QueueState> {
  final math.Random _random = math.Random();

  @override
  QueueState build() => const QueueState();

  void setQueue(List<Song> songs, {int startIndex = 0}) {
    final queue = List<Song>.from(songs);
    // 空队列时 length-1 == -1，clamp(0,-1) 会抛 ArgumentError，需先判空
    final index = queue.isEmpty ? 0 : startIndex.clamp(0, queue.length - 1);
    state = state.copyWith(queue: queue, currentIndex: index);
  }

  void addToQueue(Song song) {
    state = state.copyWith(queue: [...state.queue, song]);
  }

  void playNext(Song song) {
    final queue = List<Song>.from(state.queue)..insert(
      state.currentIndex + 1,
      song,
    );
    state = state.copyWith(queue: queue);
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= state.queue.length) return;
    final queue = List<Song>.from(state.queue);
    var currentIndex = state.currentIndex;
    if (index == currentIndex) {
      queue.removeAt(index);
      if (currentIndex >= queue.length) currentIndex = 0;
    } else {
      if (index < currentIndex) currentIndex--;
      queue.removeAt(index);
    }
    state = state.copyWith(queue: queue, currentIndex: currentIndex);
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final queue = List<Song>.from(state.queue);
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    var currentIndex = state.currentIndex;
    if (currentIndex == oldIndex) {
      currentIndex = newIndex;
    } else if (oldIndex < currentIndex && newIndex >= currentIndex) {
      currentIndex--;
    } else if (oldIndex > currentIndex && newIndex <= currentIndex) {
      currentIndex++;
    }
    state = state.copyWith(queue: queue, currentIndex: currentIndex);
  }

  /// 按 id 移除队列中所有同 id 条目（曲库删除歌曲时同步清理）。
  /// 移除当前曲时 currentIndex 保持指向同位置（即下一首），
  /// 越界时夹紧到有效范围。
  void removeSongById(String id) {
    final queue = List<Song>.from(state.queue);
    final before = queue.length;
    var currentIndex = state.currentIndex;
    for (var i = queue.length - 1; i >= 0; i--) {
      if (queue[i].id != id) continue;
      if (i < currentIndex) currentIndex--;
      queue.removeAt(i);
    }
    if (queue.length == before) return;
    if (currentIndex >= queue.length) {
      currentIndex = queue.isEmpty ? 0 : queue.length - 1;
    }
    state = state.copyWith(queue: queue, currentIndex: currentIndex);
  }

  void playSongById(Song song) {
    final idx = state.queue.indexWhere((s) => s.id == song.id);
    if (idx >= 0) {
      state = state.copyWith(currentIndex: idx);
    } else {
      state = state.copyWith(
        queue: [...state.queue, song],
        currentIndex: state.queue.length,
      );
    }
  }

  void advanceTo(int index) {
    if (index >= 0 && index < state.queue.length) {
      state = state.copyWith(currentIndex: index);
    }
  }

  int findNextIndex() {
    final s = state;
    if (s.queue.isEmpty) return 0;
    final shouldShuffle = s.shuffle || s.loopMode == LoopMode.shuffle;
    if (shouldShuffle && s.queue.length > 1) {
      return (s.currentIndex + 1 + _random.nextInt(s.queue.length - 1)) %
          s.queue.length;
    }
    return (s.currentIndex + 1) % s.queue.length;
  }

  void setLoopMode(LoopMode mode) {
    state = state.copyWith(loopMode: mode);
    ref.read(preferencesRepositoryProvider).setLoopMode(mode.name);
  }

  void toggleLoopMode() {
    const modes = [LoopMode.list, LoopMode.single, LoopMode.shuffle];
    final idx = modes.indexOf(state.loopMode);
    setLoopMode(modes[(idx + 1) % modes.length]);
  }

  void toggleShuffle() {
    state = state.copyWith(shuffle: !state.shuffle);
    ref.read(preferencesRepositoryProvider).setShuffle(state.shuffle);
  }

  /// 库加载完成后以导入歌曲初始化队列（不触发 UI 通知风暴，直接整体替换）。
  void onImportedSongsLoaded(List<Song> songs) {
    state = state.copyWith(queue: List<Song>.from(songs), currentIndex: 0);
  }

  void onImportAdded(List<Song> songs) {
    final existingPaths = state.queue
        .map((s) => s.path)
        .whereType<String>()
        .toSet();
    final newSongs = songs
        .where((s) => s.path != null && !existingPaths.contains(s.path))
        .toList();
    if (newSongs.isEmpty) return;
    state = state.copyWith(queue: [...state.queue, ...newSongs]);
  }
}

final queueProvider = NotifierProvider<QueueNotifier, QueueState>(
  QueueNotifier.new,
);
