import 'package:flutter/material.dart';

/// Deterministic grayscale gradient for a track cover.
///
/// We intentionally avoid color: the UI is monochrome (near-black + white,
/// gray scale for hierarchy). The "content" that brings visual variety is the
/// cover art itself, so each track gets a stable light-to-dark gray gradient
/// derived from its id — distinct per track, never colorful.
List<Color> coverGradient(String seed) {
  var h = 2166136261;
  for (final r in seed.runes) {
    h ^= r;
    h = (h * 16777619) & 0x7fffffff;
  }
  final base = 16 + (h % 38); // 16..53
  final top = (base + 34).clamp(26, 86);
  final bot = (base - 4).clamp(8, 50);
  return [
    Color.fromARGB(255, top, top, top),
    Color.fromARGB(255, bot, bot, bot),
  ];
}
