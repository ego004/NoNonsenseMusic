import 'package:flutter/widgets.dart';

import '../core/library.dart';
import '../core/lyrics.dart';
import '../core/player.dart';
import '../core/settings.dart';

/// The one player and the one library, for every screen below (the Mac app's `.environment`).
class Scope extends InheritedWidget {
  final Player player;
  final Library library;
  final LyricsStore lyrics;
  final Settings settings;
  const Scope({super.key, required this.player, required this.library, required this.lyrics, required this.settings, required super.child});

  static Scope of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<Scope>()!;
  @override
  bool updateShouldNotify(Scope old) => false; // the objects never change; their own listeners redraw what reads them
}
