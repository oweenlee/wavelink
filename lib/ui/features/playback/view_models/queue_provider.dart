import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../../../domain/models/song.dart';
import '../../../../domain/models/playback_types.dart';
import '../../../../data/repositories/preferences_repository.dart';

class QueueProvider extends ChangeNotifier {
  QueueProvider({required PreferencesRepository prefsRepo})
      : _prefsRepo = prefsRepo;

  final PreferencesRepository _prefsRepo;
  List<Song> _queue = [];
  int _currentIndex = 0;
  LoopMode _loopMode = LoopMode.list;
  bool _shuffle = false;
  final math.Random _random = math.Random();

  List<Song> get queue => _queue;
  int get currentIndex => _currentIndex;
  LoopMode get loopMode => _loopMode;
  bool get shuffle => _shuffle;

  bool get hasSong => _queue.isNotEmpty;
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;

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
    final shouldShuffle = _shuffle || _loopMode == LoopMode.shuffle;
    if (shouldShuffle && _queue.length > 1) {
      return (_currentIndex + 1 + _random.nextInt(_queue.length - 1)) %
          _queue.length;
    }
    return (_currentIndex + 1) % _queue.length;
  }

  void setLoopMode(LoopMode mode) {
    _loopMode = mode;
  }

  void toggleLoopMode() {
    const modes = [LoopMode.list, LoopMode.single, LoopMode.shuffle];
    final idx = modes.indexOf(_loopMode);
    _loopMode = modes[(idx + 1) % modes.length];
    _prefsRepo.setLoopMode(_loopMode.name);
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _prefsRepo.setShuffle(_shuffle);
    notifyListeners();
  }

  void onImportedSongsLoaded(List<Song> songs) {
    _queue = List.from(songs);
    _currentIndex = 0;
  }

  void onImportAdded(List<Song> songs) {
    final existingPaths = _queue.map((s) => s.path).whereType<String>().toSet();
    final newSongs = songs.where((s) => s.path != null && !existingPaths.contains(s.path)).toList();
    if (newSongs.isEmpty) return;
    _queue.addAll(newSongs);
    notifyListeners();
  }

  void onRescan(List<Song> songs) {
    for (final s in songs) {
      final idx = _queue.indexWhere((q) => q.path == s.path);
      if (idx >= 0) _queue[idx] = s;
    }
  }
}
