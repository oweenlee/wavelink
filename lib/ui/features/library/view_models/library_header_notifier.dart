import 'package:flutter/foundation.dart';

/// Shared state for the Library page header — search bar visibility and query.
/// Used by both AppShell (icon buttons) and LibraryPage (search bar, filtering).
class LibraryHeaderNotifier extends ChangeNotifier {
  bool _isSearchVisible = false;
  String _searchQuery = '';

  bool get isSearchVisible => _isSearchVisible;
  String get searchQuery => _searchQuery;

  void toggleSearch() {
    _isSearchVisible = !_isSearchVisible;
    if (!_isSearchVisible) _searchQuery = '';
    notifyListeners();
  }

  void setQuery(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  void closeSearch() {
    _isSearchVisible = false;
    _searchQuery = '';
    notifyListeners();
  }
}
