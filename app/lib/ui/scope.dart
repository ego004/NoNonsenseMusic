import 'package:flutter/widgets.dart';

import '../core/library.dart';
import '../core/player.dart';

/// The one player and the one library, for every screen below (the Mac app's `.environment`).
class Scope extends InheritedWidget {
  final Player player;
  final Library library;
  const Scope({super.key, required this.player, required this.library, required super.child});

  static Scope of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<Scope>()!;
  @override
  bool updateShouldNotify(Scope old) => false; // the objects never change; their own listeners redraw what reads them
}
