import 'dart:math';

/// Two shuffles: true random, and Spotify's 2014 "spread each artist out" version (as the Mac app's Shuffle.swift).
class Shuffle {
  /// Fisher–Yates: every order equally likely. Returns a new list.
  static List<T> fisherYates<T>(List<T> items, Random rng) {
    final result = [...items];
    for (var i = result.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = result[i];
      result[i] = result[j];
      result[j] = t;
    }
    return result;
  }

  /// An artist with k songs gets positions offset + i/k (+ a little jitter): their songs land evenly through the list.
  static List<T> artistSpread<T>(List<T> items, String Function(T) artist, Random rng) {
    final byArtist = <String, List<T>>{};
    for (final item in items) {
      byArtist.putIfAbsent(artist(item), () => []).add(item);
    }
    final placed = <(double, T)>[];
    for (final songs in byArtist.values) {
      final k = songs.length.toDouble();
      final offset = rng.nextDouble() / k;
      final shuffled = fisherYates(songs, rng);
      for (var i = 0; i < shuffled.length; i++) {
        final jitter = (rng.nextDouble() * 0.2 - 0.1) / k;
        placed.add((offset + i / k + jitter, shuffled[i]));
      }
    }
    placed.sort((a, b) => a.$1.compareTo(b.$1));
    return placed.map((p) => p.$2).toList();
  }
}
