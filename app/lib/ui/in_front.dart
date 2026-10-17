import 'dart:async';

import 'package:flutter/widgets.dart';

/// Whether the window is in front: focused and shown.
///
/// UI that advances by itself (the progress tick, lyrics following the song) moves only while this is true, and
/// catches up when the user returns: a visible Flutter window pays about 8 ms of CPU for every frame it draws,
/// even for a single tick, and playback used 1.46% CPU with the window in front against 0.67% behind. Animation
/// that no one sees is wasted work.
final inFront = ValueNotifier<bool>(true);

final AppLifecycleListener _listener = AppLifecycleListener(onStateChange: (s) => inFront.value = s == AppLifecycleState.resumed);

/// One tick a second for every time line on screen, while the window is in front and something listens. Each line
/// kept a timer of its own, so two lines on screen drew a frame each, at different moments: two frames a second
/// instead of one (15 Oct: Home's song and the player bar). On one tick they are drawn in the same frame.
final secondTick = _SecondTick();

class _SecondTick extends ChangeNotifier {
  _SecondTick() {
    inFront.addListener(_run);
  }

  Timer? _timer;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _run();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _run();
  }

  void _run() {
    if (hasListeners && inFront.value) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// Begin observing the app lifecycle and seed [inFront] from the current state. Call once at startup.
void watchInFront() {
  _listener; // referencing the field forces its lazy initialization
  inFront.value = WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
}
