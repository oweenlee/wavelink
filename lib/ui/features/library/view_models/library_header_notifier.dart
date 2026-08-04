import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared state for the Library page header — search bar visibility and query.
/// Used by both AppShell (icon buttons) and LibraryPage (search bar, filtering).
class LibraryHeaderState {
  final bool isSearchVisible;
  final String searchQuery;

  const LibraryHeaderState({
    this.isSearchVisible = false,
    this.searchQuery = '',
  });

  LibraryHeaderState copyWith({bool? isSearchVisible, String? searchQuery}) {
    return LibraryHeaderState(
      isSearchVisible: isSearchVisible ?? this.isSearchVisible,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }
}

class LibraryHeaderNotifier extends Notifier<LibraryHeaderState> {
  @override
  LibraryHeaderState build() => const LibraryHeaderState();

  void toggleSearch() {
    final visible = !state.isSearchVisible;
    state = LibraryHeaderState(
      isSearchVisible: visible,
      searchQuery: visible ? state.searchQuery : '',
    );
  }

  void setQuery(String q) {
    state = state.copyWith(searchQuery: q);
  }

  void closeSearch() {
    state = const LibraryHeaderState();
  }
}

final libraryHeaderProvider =
    NotifierProvider<LibraryHeaderNotifier, LibraryHeaderState>(
      LibraryHeaderNotifier.new,
    );
