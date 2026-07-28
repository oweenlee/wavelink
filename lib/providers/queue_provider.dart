import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../models/song.dart';
import '../models/playback_types.dart';
import '../services/preferences_service.dart';

class QueueProvider extends ChangeNotifier {
  List<Song> _queue = [];
  int _currentIndex = 0;
  LoopMode _loopMode = LoopMode.list;
  bool _shuffle = false;
  final math.Random _random = math.Random();

  // ── getters ──

  List<Song> get queue => _queue;
  int get currentIndex => _currentIndex;
  LoopMode get loopMode => _loopMode;
  bool get shuffle => _shuffle;

  bool get hasSong => _queue.isNotEmpty;
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;

  // ── 队列操作 ──

  void setQueue(List<Song> songs, {int startIndex = 0}) {
    _queue = List.from(songs);
    _currentIndex = startIndex.clamp(0, _queue.length - 1);
  }

  void addToQueue(Song song) {
    _queue.add(song);
    notifyListeners();
  }

  void playNext(Song song) {
    _queue.insert(_currentIndex + 1, song);
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (index == _currentIndex) {
      _queue.removeAt(index);
      if (_currentIndex >= _queue.length) _currentIndex = 0;
    } else {
      if (index < _currentIndex) _currentIndex--;
      _queue.removeAt(index);
    }
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);
    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    notifyListeners();
  }

  // ── 导航 ──

  void playSongById(Song song) {
    final idx = _queue.indexWhere((s) => s.id == song.id);
    if (idx >= 0) {
      _currentIndex = idx;
    }
  }

  void advanceTo(int index) {
    if (index >= 0 && index < _queue.length) {
      _currentIndex = index;
    }
  }

  int findNextIndex() {
    if (_queue.isEmpty) return 0;
    if (_shuffle && _queue.length > 1) {
      return (_currentIndex + 1 + _random.nextInt(_queue.length - 1)) %
          _queue.length;
    }
    return (_currentIndex + 1) % _queue.length;
  }

  void setLoopMode(LoopMode mode) {
    _loopMode = mode;
  }

  // ── 模式切换 ──

  void toggleLoopMode() {
    const modes = [LoopMode.list, LoopMode.single, LoopMode.shuffle];
    final idx = modes.indexOf(_loopMode);
    _loopMode = modes[(idx + 1) % modes.length];
    PreferencesService.instance.setLoopMode(_loopMode.name);
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    PreferencesService.instance.setShuffle(_shuffle);
    notifyListeners();
  }

  // ── 导入回调（由 PlaybackProvider 协调器调用） ──

  void onImportedSongsLoaded(List<Song> songs) {
    _queue = List.from(songs);
    _currentIndex = 0;
  }

  void onImportAdded(List<Song> songs) {
    _queue.addAll(songs);
    if (_queue.length == songs.length) _currentIndex = 0;
  }

  void onRescan(List<Song> songs) {
    for (final s in songs) {
      final idx = _queue.indexWhere((q) => q.path == s.path);
      if (idx >= 0) _queue[idx] = s;
    }
  }
}
