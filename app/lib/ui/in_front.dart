import 'package:flutter/widgets.dart';

/// Whether the window is the one in front (focused and shown). What moves by itself (the progress line's tick, the
/// lyrics following the song) moves only then, and catches up the moment you come back: a visible Flutter window
/// pays ~8 ms of CPU for every frame it draws, even for a tick, and playing took 1.46% with the window in front
/// against 0.67% behind (measured 8 Oct, Release, the kernel's CPU account). Nobody reads a line nobody sees.
final inFront = ValueNotifier<bool>(true);

final AppLifecycleListener _listener = AppLifecycleListener(onStateChange: (s) => inFront.value = s == AppLifecycleState.resumed);

/// Call once at start.
void watchInFront() {
  _listener; // created on first use
  inFront.value = WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
}
